// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.15;

import {OwnableUpgradeable} from "openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "openzeppelin-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {SafeERC20, IERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {SignedInt, SignedIntOps} from "../lib/SignedInt.sol";
import {UniERC20} from "../lib/UniERC20.sol";
import {MathUtils} from "../lib/MathUtils.sol";
import {PositionUtils} from "../lib/PositionUtils.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {ILPToken} from "../interfaces/ILPToken.sol";
import {IPool, Side, TokenWeight} from "../interfaces/IPool.sol";
import {
    PoolStorage,
    Position,
    PoolTokenInfo,
    Fee,
    AssetInfo,
    INTEREST_RATE_PRECISION,
    FEE_PRECISION,
    LP_INITIAL_PRICE,
    MAX_BASE_SWAP_FEE,
    MAX_TAX_BASIS_POINT,
    MAX_POSITION_FEE
} from "./PoolStorage.sol";
import {PoolErrors} from "./PoolErrors.sol";
import {IPositionHook} from "../interfaces/IPositionHook.sol";

struct IncreasePositionVars {
    uint256 reserveAdded;
    uint256 collateralAmount;
    uint256 collateralValueAdded;
    uint256 feeValue;
    uint256 daoFee;
    uint256 indexPrice;
    uint256 sizeChanged;
}

/// @notice common variable used accross decrease process
struct DecreasePositionVars {
    /// @notice santinized input: collateral value able to be withdraw
    uint256 collateralReduced;
    /// @notice santinized input: position size to decrease, caped to position's size
    uint256 sizeChanged;
    /// @notice current price of index
    uint256 indexPrice;
    /// @notice current price of collateral
    uint256 collateralPrice;
    /// @notice postion's remaining collateral value in USD after decrease position
    uint256 remainingCollateral;
    /// @notice reserve reduced due to reducion process
    uint256 reserveReduced;
    /// @notice total value of fee to be collect (include dao fee and LP fee)
    uint256 feeValue;
    /// @notice amount of collateral taken as fee
    uint256 daoFee;
    /// @notice real transfer out amount to user
    uint256 payout;
    SignedInt pnl;
    SignedInt poolAmountReduced;
}

contract Pool is Initializable, PoolStorage, OwnableUpgradeable, ReentrancyGuardUpgradeable, IPool {
    using SignedIntOps for SignedInt;
    using UniERC20 for IERC20;
    using SafeERC20 for IERC20;

    /* =========== MODIFIERS ========== */
    modifier onlyOrderManager() {
        _requireOrderManager();
        _;
    }

    modifier onlyAsset(address _token) {
        _validateAsset(_token);
        _;
    }

    modifier onlyListedToken(address _token) {
        _requireListedToken(_token);
        _;
    }

    /* ======== INITIALIZERS ========= */
    function initialize(
        uint256 _maxLeverage,
        uint256 _positionFee,
        uint256 _liquidationFee,
        uint256 _interestRate,
        uint256 _accrualInterval
    )
        external
        initializer
    {
        __Ownable_init();
        __ReentrancyGuard_init();
        if (_accrualInterval == 0) {
            revert PoolErrors.InvalidInterval();
        }
        if (_maxLeverage == 0) {
            revert PoolErrors.InvalidMaxLeverage();
        }
        maxLeverage = _maxLeverage;
        fee.positionFee = _positionFee;
        fee.liquidationFee = _liquidationFee;
        interestRate = _interestRate;
        accrualInterval = _accrualInterval;
        fee.daoFee = FEE_PRECISION;
    }

    // ========= View functions =========

    function validateToken(address _indexToken, address _collateralToken, Side _side, bool _isIncrease)
        external
        view
        returns (bool)
    {
        return _validateToken(_indexToken, _collateralToken, _side, _isIncrease);
    }

    function getPoolAsset(address _token) external view returns (AssetInfo memory) {
        return _getPoolAsset(_token);
    }

    function getAllTranchesLength() external view returns (uint256) {
        return allTranches.length;
    }

    function getPoolValue() external view returns (uint256) {
        return _getPoolValue();
    }

    function getTrancheValue(address _tranche) external view returns (uint256 sum) {
        if (!isTranche[_tranche]) {
            revert PoolErrors.InvalidTranche(_tranche);
        }
        return _getTrancheValue(_tranche);
    }

    // ============= Mutative functions =============
    function addLiquidity(address _tranche, address _token, uint256 _amountIn, uint256 _minLpAmount, address _to)
        external
        payable
        nonReentrant
        onlyListedToken(_token)
    {
        if (!isTranche[_tranche]) {
            revert PoolErrors.InvalidTranche(_tranche);
        }
        _accrueInterest(_token);
        _amountIn = _transferIn(_token, _amountIn);
        if (_amountIn == 0) {
            revert PoolErrors.ZeroAmount();
        }

        (uint256 amountInAfterFee, uint256 feeAmount, uint256 lpAmount) = _calcAddLiquidity(_tranche, _token, _amountIn);
        if (lpAmount < _minLpAmount) {
            revert PoolErrors.SlippageExceeded();
        }

        poolTokens[_token].feeReserve += feeAmount;
        trancheAssets[_tranche][_token].poolAmount += amountInAfterFee;

        ILPToken(_tranche).mint(_to, lpAmount);
        emit LiquidityAdded(_tranche, msg.sender, _token, _amountIn, lpAmount, feeAmount);
    }

    function removeLiquidity(address _tranche, address _tokenOut, uint256 _lpAmount, uint256 _minOut, address _to)
        external
        nonReentrant
        onlyAsset(_tokenOut)
    {
        if (!isTranche[_tranche]) {
            revert PoolErrors.InvalidTranche(_tranche);
        }
        _accrueInterest(_tokenOut);
        ILPToken lpToken = ILPToken(_tranche);
        if (_lpAmount == 0) {
            revert PoolErrors.ZeroAmount();
        }

        (uint256 outAmount, uint256 outAmountAfterFee, uint256 feeAmount) =
            _calcRemoveLiquidity(_tranche, _tokenOut, _lpAmount);
        if (outAmountAfterFee < _minOut) {
            revert PoolErrors.SlippageExceeded();
        }

        uint256 trancheBalance = trancheAssets[_tranche][_tokenOut].poolAmount;
        if (trancheBalance < outAmount) {
            revert PoolErrors.RemoveLiquidityTooMuch(_tranche, outAmount, trancheBalance);
        }

        poolTokens[_tokenOut].feeReserve += feeAmount;
        _decreaseTranchePoolAmount(_tranche, _tokenOut, outAmountAfterFee);

        lpToken.burnFrom(msg.sender, _lpAmount);
        _doTransferOut(_tokenOut, _to, outAmountAfterFee);
        emit LiquidityRemoved(_tranche, msg.sender, _tokenOut, _lpAmount, outAmountAfterFee, feeAmount);
    }

    function swap(address _tokenIn, address _tokenOut, uint256 _minOut, address _to)
        external
        nonReentrant
        onlyListedToken(_tokenIn)
        onlyListedToken(_tokenOut)
    {
        if (_tokenIn == _tokenOut) {
            revert PoolErrors.SameTokenSwap(_tokenIn);
        }
        _accrueInterest(_tokenIn);
        _accrueInterest(_tokenOut);
        uint256 amountIn = _getAmountIn(_tokenIn);
        if (amountIn == 0) {
            revert PoolErrors.ZeroAmount();
        }
        (uint256 amountOut, uint256 swapFee) = _calcSwapOutput(_tokenIn, _tokenOut, amountIn);
        uint256 amountOutAfterFee = amountOut - swapFee;
        if (amountOutAfterFee < _minOut) {
            revert PoolErrors.SlippageExceeded();
        }
        poolTokens[_tokenOut].feeReserve += swapFee;
        _rebalanceTranches(_tokenIn, amountIn, _tokenOut, amountOutAfterFee);
        _doTransferOut(_tokenOut, _to, amountOutAfterFee);
        emit Swap(msg.sender, _tokenIn, _tokenOut, amountIn, amountOutAfterFee, swapFee);
    }

    function increasePosition(
        address _owner,
        address _indexToken,
        address _collateralToken,
        uint256 _sizeChanged,
        Side _side
    )
        external
        onlyOrderManager
    {
        _requireValidTokenPair(_indexToken, _collateralToken, _side, true);
        if (address(positionHook) != address(0)) {
            positionHook.preIncreasePosition(_owner, _indexToken, _collateralToken, _side, _sizeChanged, bytes(""));
        }
        uint256 borrowIndex = _accrueInterest(_collateralToken);
        IncreasePositionVars memory vars;
        bytes32 key = _getPositionKey(_owner, _indexToken, _collateralToken, _side);
        Position memory position = positions[key];
        uint256 collateralPrice = _getPrice(_collateralToken);
        vars.indexPrice = _getPrice(_indexToken);
        vars.collateralAmount = _getAmountIn(_collateralToken);
        if (vars.collateralAmount == 0) {
            revert PoolErrors.ZeroAmount();
        }
        vars.collateralValueAdded = collateralPrice * vars.collateralAmount;
        vars.sizeChanged = _sizeChanged;

        // update position
        vars.feeValue = _calcPositionFee(position, vars.sizeChanged, borrowIndex);
        vars.daoFee = vars.feeValue * fee.daoFee / collateralPrice / FEE_PRECISION;
        vars.reserveAdded = vars.sizeChanged / collateralPrice;
        position.entryPrice =
            _calcAveragePrice(_side, position.size, vars.sizeChanged, position.entryPrice, vars.indexPrice);
        position.collateralValue =
            MathUtils.zeroCapSub(position.collateralValue + vars.collateralValueAdded, vars.feeValue);
        position.size = position.size + vars.sizeChanged;
        position.borrowIndex = borrowIndex;
        position.reserveAmount += vars.reserveAdded;

        _validatePosition(position, _collateralToken, _side, true, vars.indexPrice);

        // upate pool assets
        _reservePoolAsset(key, vars, _indexToken, _collateralToken, _side);
        positions[key] = position;

        emit IncreasePosition(
            key,
            _owner,
            _collateralToken,
            _indexToken,
            vars.collateralAmount,
            vars.sizeChanged,
            _side,
            vars.indexPrice,
            vars.feeValue
            );

        emit UpdatePosition(
            key,
            position.size,
            position.collateralValue,
            position.entryPrice,
            position.borrowIndex,
            position.reserveAmount,
            vars.indexPrice
            );

        if (address(positionHook) != address(0)) {
            positionHook.postIncreasePosition(_owner, _indexToken, _collateralToken, _side, _sizeChanged, bytes(""));
        }
    }

    function decreasePosition(
        address _owner,
        address _indexToken,
        address _collateralToken,
        uint256 _collateralChanged,
        uint256 _sizeChanged,
        Side _side,
        address _receiver
    )
        external
        onlyOrderManager
    {
        _requireValidTokenPair(_indexToken, _collateralToken, _side, false);
        uint256 borrowIndex = _accrueInterest(_collateralToken);
        bytes32 key = _getPositionKey(_owner, _indexToken, _collateralToken, _side);
        Position memory position = positions[key];

        if (address(positionHook) != address(0)) {
            positionHook.preDecreasePosition(_owner, _indexToken, _collateralToken, _side, _sizeChanged, bytes(""));
        }

        DecreasePositionVars memory vars =
            _calcDecreasePayout(position, _indexToken, _collateralToken, _side, _sizeChanged, _collateralChanged);

        _releasePoolAsset(key, vars, _indexToken, _collateralToken, _side);
        position.size = position.size - vars.sizeChanged;
        position.borrowIndex = borrowIndex;
        position.reserveAmount = position.reserveAmount - vars.reserveReduced;
        // reset to actual reduced value instead of user input
        vars.collateralReduced = position.collateralValue - vars.remainingCollateral;
        position.collateralValue = vars.remainingCollateral;

        _validatePosition(position, _collateralToken, _side, false, vars.indexPrice);

        emit DecreasePosition(
            key,
            _owner,
            _collateralToken,
            _indexToken,
            vars.collateralReduced,
            vars.sizeChanged,
            _side,
            vars.indexPrice,
            vars.pnl,
            vars.feeValue
            );
        if (position.size == 0) {
            emit ClosePosition(
                key,
                position.size,
                position.collateralValue,
                position.entryPrice,
                position.borrowIndex,
                position.reserveAmount
                );
            // delete position when closed
            delete positions[key];
        } else {
            emit UpdatePosition(
                key,
                position.size,
                position.collateralValue,
                position.entryPrice,
                position.borrowIndex,
                position.reserveAmount,
                vars.indexPrice
                );
            positions[key] = position;
        }
        _doTransferOut(_collateralToken, _receiver, vars.payout);

        if (address(positionHook) != address(0)) {
            positionHook.postDecreasePosition(_owner, _indexToken, _collateralToken, _side, _sizeChanged, bytes(""));
        }
    }

    function liquidatePosition(address _account, address _indexToken, address _collateralToken, Side _side) external {
        _requireValidTokenPair(_indexToken, _collateralToken, _side, false);
        uint256 borrowIndex = _accrueInterest(_collateralToken);

        bytes32 key = _getPositionKey(_account, _indexToken, _collateralToken, _side);
        Position memory position = positions[key];
        if (!_liquidatePositionAllowed(position, _side, oracle.getPrice(_indexToken), borrowIndex)) {
            revert PoolErrors.PositionNotLiquidated(key);
        }
        if (address(positionHook) != address(0)) {
            positionHook.preDecreasePosition(_account, _indexToken, _collateralToken, _side, position.size, bytes(""));
        }

        DecreasePositionVars memory vars =
            _calcDecreasePayout(position, _indexToken, _collateralToken, _side, position.size, position.collateralValue);

        uint256 liquidationFee = fee.liquidationFee / vars.collateralPrice;
        vars.poolAmountReduced = vars.poolAmountReduced.add(liquidationFee);
        _releasePoolAsset(key, vars, _indexToken, _collateralToken, _side);

        emit LiquidatePosition(
            key,
            _account,
            _collateralToken,
            _indexToken,
            _side,
            position.size,
            position.collateralValue - vars.remainingCollateral,
            position.reserveAmount,
            vars.indexPrice,
            vars.pnl,
            vars.feeValue
            );

        delete positions[key];
        _doTransferOut(_collateralToken, msg.sender, liquidationFee);

        if (address(positionHook) != address(0)) {
            positionHook.postDecreasePosition(_account, _indexToken, _collateralToken, _side, position.size, bytes(""));
        }
    }

    // ========= ADMIN FUNCTIONS ========
    function addTranche(address _tranche) external onlyOwner {
        if (_tranche == address(0)) {
            revert PoolErrors.ZeroAddress();
        }
        if (isTranche[_tranche]) {
            revert PoolErrors.TrancheAlreadyAdded(_tranche);
        }
        isTranche[_tranche] = true;
        allTranches.push(_tranche);
        emit TrancheAdded(_tranche);
    }

    struct RiskConfig {
        address tranche;
        uint256 riskFactor;
    }

    function setRiskFactor(address _token, RiskConfig[] memory _config) external onlyOwner onlyAsset(_token) {
        uint256 total = totalRiskFactor[_token];
        for (uint256 i = 0; i < _config.length; i++) {
            (address tranche, uint256 factor) = (_config[i].tranche, _config[i].riskFactor);
            if (!isTranche[tranche]) {
                revert PoolErrors.InvalidTranche(tranche);
            }
            total = total + factor - riskFactor[_token][tranche];
            riskFactor[_token][tranche] = factor;
        }
        totalRiskFactor[_token] = total;
        emit TokenRiskFactorUpdated(_token);
    }

    function addToken(address _token, bool _isStableCoin) external onlyOwner {
        if (isAsset[_token]) {
            revert PoolErrors.DuplicateToken(_token);
        }
        isAsset[_token] = true;
        isListed[_token] = true;
        allAssets.push(_token);
        isStableCoin[_token] = _isStableCoin;
        emit TokenWhitelisted(_token);
    }

    function delistToken(address _token) external onlyOwner {
        if (!isListed[_token]) {
            revert PoolErrors.TokenNotListed(_token);
        }
        isListed[_token] = false;
        uint256 weight = targetWeights[_token];
        totalWeight -= weight;
        targetWeights[_token] = 0;
        emit TokenWhitelisted(_token);
    }

    function setMaxLeverage(uint256 _maxLeverage) external onlyOwner {
        if (_maxLeverage == 0) {
            revert PoolErrors.InvalidMaxLeverage();
        }
        maxLeverage = _maxLeverage;
        emit MaxLeverageChanged(_maxLeverage);
    }

    function setOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) {
            revert PoolErrors.ZeroAddress();
        }
        address oldOracle = address(oracle);
        oracle = IOracle(_oracle);
        emit OracleChanged(oldOracle, _oracle);
    }

    function setSwapFee(
        uint256 _baseSwapFee,
        uint256 _taxBasisPoint,
        uint256 _stableCoinBaseSwapFee,
        uint256 _stableCoinTaxBasisPoint
    )
        external
        onlyOwner
    {
        _validateMaxValue(_baseSwapFee, MAX_BASE_SWAP_FEE);
        _validateMaxValue(_stableCoinBaseSwapFee, MAX_BASE_SWAP_FEE);
        _validateMaxValue(_taxBasisPoint, MAX_TAX_BASIS_POINT);
        _validateMaxValue(_stableCoinTaxBasisPoint, MAX_TAX_BASIS_POINT);
        fee.baseSwapFee = _baseSwapFee;
        fee.taxBasisPoint = _taxBasisPoint;
        fee.stableCoinBaseSwapFee = _stableCoinBaseSwapFee;
        fee.stableCoinTaxBasisPoint = _stableCoinTaxBasisPoint;
        emit SwapFeeSet(_baseSwapFee, _taxBasisPoint, _stableCoinBaseSwapFee, _stableCoinTaxBasisPoint);
    }

    function setPositionFee(uint256 _positionFee, uint256 _liquidationFee) external onlyOwner {
        _validateMaxValue(_positionFee, MAX_POSITION_FEE);
        fee.positionFee = _positionFee;
        fee.liquidationFee = _liquidationFee;
        emit PositionFeeSet(_positionFee, _liquidationFee);
    }

    function setDaoFee(uint256 _daoFee) external onlyOwner {
        _validateMaxValue(_daoFee, FEE_PRECISION);
        fee.daoFee = _daoFee;
        emit DaoFeeSet(_daoFee);
    }

    function setInterestRate(uint256 _interestRate, uint256 _accrualInterval) external onlyOwner {
        if (_accrualInterval == 0) {
            revert PoolErrors.InvalidInterval();
        }
        interestRate = _interestRate;
        accrualInterval = _accrualInterval;
        emit InterestRateSet(_interestRate, _accrualInterval);
    }

    function setOrderManager(address _orderManager) external onlyOwner {
        if (_orderManager == address(0)) {
            revert PoolErrors.ZeroAddress();
        }
        orderManager = _orderManager;
        emit SetOrderManager(_orderManager);
    }

    function withdrawFee(address _token, address _recipient) external onlyAsset(_token) {
        _validateFeeDistributor();
        uint256 amount = poolTokens[_token].feeReserve;
        poolTokens[_token].feeReserve = 0;
        _doTransferOut(_token, _recipient, amount);
        emit DaoFeeWithdrawn(_token, _recipient, amount);
    }

    /// @notice reduce DAO fee by distributing to pool amount;
    function reduceDaoFee(address _token, uint256 _amount) public onlyAsset(_token) {
        _validateFeeDistributor();
        _amount = MathUtils.min(_amount, poolTokens[_token].feeReserve);
        uint256[] memory shares = _calcTrancheSharesAmount(_token, _amount, false);
        for (uint256 i = 0; i < shares.length; i++) {
            address tranche = allTranches[i];
            trancheAssets[tranche][_token].poolAmount += shares[i];
        }
        poolTokens[_token].feeReserve -= _amount;
        emit DaoFeeReduced(_token, _amount);
    }

    function setFeeDistributor(address _feeDistributor) external onlyOwner {
        if (_feeDistributor == address(0)) {
            revert PoolErrors.ZeroAddress();
        }
        feeDistributor = _feeDistributor;
        emit FeeDistributorSet(feeDistributor);
    }

    function setTargetWeight(TokenWeight[] memory tokens) external onlyOwner {
        if (tokens.length != allAssets.length) {
            revert PoolErrors.RequireAllTokens();
        }
        uint256 total = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            TokenWeight memory item = tokens[i];
            assert(isAsset[item.token]);
            // unlisted token always has zero weight
            uint256 weight = isListed[item.token] ? item.weight : 0;
            targetWeights[item.token] = weight;
            total += weight;
        }
        totalWeight = total;
        emit TokenWeightSet(tokens);
    }

    function setMaxPositionSize(uint256 _maxSize) external onlyOwner {
        maxPositionSize = _maxSize;
        emit MaxPositionSizeSet(_maxSize);
    }

    function setPositionHook(address _hook) external onlyOwner {
        positionHook = IPositionHook(_hook);
        emit PositionHookChanged(_hook);
    }

    receive() external payable onlyOrderManager {}

    // ======== internal functions =========
    function _validateToken(address _indexToken, address _collateralToken, Side _side, bool _isIncrease)
        internal
        view
        returns (bool)
    {
        if (!isAsset[_indexToken] || !isAsset[_collateralToken]) {
            return false;
        }

        if (_isIncrease && !isListed[_indexToken]) {
            return false;
        }

        if (_side == Side.LONG) {
            return _indexToken == _collateralToken;
        }
        return isStableCoin[_collateralToken];
    }

    function _calcAddLiquidity(address _tranche, address _token, uint256 _amountIn)
        internal
        view
        returns (uint256 amountInAfterFee, uint256 feeAmount, uint256 lpAmount)
    {
        uint256 tokenPrice = _getPrice(_token);
        uint256 poolValue = _getTrancheValue(_tranche);
        uint256 valueChange = _amountIn * tokenPrice;
        uint256 _fee = _calcAdjustedFee(poolValue, _token, tokenPrice, valueChange, true);
        amountInAfterFee = (_amountIn * (FEE_PRECISION - _fee)) / FEE_PRECISION;
        feeAmount = _amountIn - amountInAfterFee;

        uint256 lpSupply = ILPToken(_tranche).totalSupply();
        if (lpSupply == 0 || poolValue == 0) {
            lpAmount = (_amountIn * tokenPrice) / LP_INITIAL_PRICE;
        } else {
            lpAmount = (amountInAfterFee * tokenPrice * lpSupply) / poolValue;
        }
    }

    function _calcRemoveLiquidity(address _tranche, address _tokenOut, uint256 _lpAmount)
        internal
        view
        returns (uint256 outAmount, uint256 outAmountAfterFee, uint256 feeAmount)
    {
        uint256 tokenPrice = _getPrice(_tokenOut);
        uint256 poolValue = _getTrancheValue(_tranche);
        uint256 totalSupply = ILPToken(_tranche).totalSupply();
        uint256 valueChange = (_lpAmount * poolValue) / totalSupply;
        uint256 _fee = _calcAdjustedFee(poolValue, _tokenOut, tokenPrice, valueChange, false);
        outAmount = (_lpAmount * poolValue) / totalSupply / tokenPrice;
        outAmountAfterFee = ((FEE_PRECISION - _fee) * outAmount) / FEE_PRECISION;
        feeAmount = outAmount - outAmountAfterFee;
    }

    function _transferIn(address _token, uint256 _amount) internal returns (uint256) {
        if (_token != UniERC20.ETH) {
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        } else if (msg.value != _amount) {
            revert PoolErrors.InvalidTransferInAmount(_amount, msg.value);
        }
        return _getAmountIn(_token);
    }

    function _calcSwapOutput(address _tokenIn, address _tokenOut, uint256 _amountIn)
        internal
        view
        returns (uint256 amountOut, uint256 feeAmount)
    {
        uint256 priceIn = _getPrice(_tokenIn);
        uint256 priceOut = _getPrice(_tokenOut);
        uint256 valueChange = _amountIn * priceIn;
        uint256 poolValue = _getPoolValue();
        uint256 feeIn = _calcAdjustedFee(poolValue, _tokenIn, priceIn, valueChange, true);
        uint256 feeOut = _calcAdjustedFee(poolValue, _tokenOut, priceOut, valueChange, false);
        uint256 _fee = feeIn > feeOut ? feeIn : feeOut;

        amountOut = valueChange / priceOut;
        feeAmount = (valueChange * _fee) / priceOut / FEE_PRECISION;
    }

    function _getPositionKey(address _owner, address _indexToken, address _collateralToken, Side _side)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_owner, _indexToken, _collateralToken, _side));
    }

    function _validatePosition(
        Position memory _position,
        address _collateralToken,
        Side _side,
        bool _isIncrease,
        uint256 _indexPrice
    )
        internal
        view
    {
        if ((_isIncrease && _position.size == 0) || (maxPositionSize > 0 && _position.size > maxPositionSize)) {
            revert PoolErrors.InvalidPositionSize();
        }

        uint256 borrowIndex = poolTokens[_collateralToken].borrowIndex;
        if (_position.size < _position.collateralValue || _position.size > _position.collateralValue * maxLeverage) {
            revert PoolErrors.InvalidLeverage(_position.size, _position.collateralValue, maxLeverage);
        }
        if (_liquidatePositionAllowed(_position, _side, _indexPrice, borrowIndex)) {
            revert PoolErrors.UpdateCauseLiquidation();
        }
    }

    function _requireValidTokenPair(address _indexToken, address _collateralToken, Side _side, bool _isIncrease)
        internal
        view
    {
        if (!_validateToken(_indexToken, _collateralToken, _side, _isIncrease)) {
            revert PoolErrors.InvalidTokenPair(_indexToken, _collateralToken);
        }
    }

    function _validateAsset(address _token) internal view {
        if (!isAsset[_token]) {
            revert PoolErrors.UnknownToken(_token);
        }
    }

    function _requireListedToken(address _token) internal view {
        if (!isListed[_token]) {
            revert PoolErrors.AssetNotListed(_token);
        }
    }

    function _requireOrderManager() internal view {
        if (msg.sender != orderManager) {
            revert PoolErrors.OrderManagerOnly();
        }
    }

    function _validateFeeDistributor() internal view {
        if (msg.sender != feeDistributor) {
            revert PoolErrors.FeeDistributorOnly();
        }
    }

    function _validateMaxValue(uint256 _input, uint256 _max) internal pure {
        if (_input > _max) {
            revert PoolErrors.ValueTooHigh(_max);
        }
    }

    function _getAmountIn(address _token) internal returns (uint256 amount) {
        uint256 balance = IERC20(_token).getBalance(address(this));
        amount = balance - poolTokens[_token].poolBalance;
        poolTokens[_token].poolBalance = balance;
    }

    function _doTransferOut(address _token, address _to, uint256 _amount) internal {
        if (_amount > 0) {
            IERC20 token = IERC20(_token);
            token.transferTo(_to, _amount);
            poolTokens[_token].poolBalance = token.getBalance(address(this));
        }
    }

    function _accrueInterest(address _token) internal returns (uint256) {
        PoolTokenInfo memory tokenInfo = poolTokens[_token];
        AssetInfo memory asset = _getPoolAsset(_token);
        uint256 _now = block.timestamp;
        if (tokenInfo.lastAccrualTimestamp == 0) {
            // accrue interest for the first time
            tokenInfo.lastAccrualTimestamp = (_now / accrualInterval) * accrualInterval;
        } else {
            uint256 nInterval = (_now - tokenInfo.lastAccrualTimestamp) / accrualInterval;
            if (nInterval == 0) {
                return tokenInfo.borrowIndex;
            }

            tokenInfo.borrowIndex += (nInterval * interestRate * asset.reservedAmount) / asset.poolAmount;
            tokenInfo.lastAccrualTimestamp += nInterval * accrualInterval;
        }

        poolTokens[_token] = tokenInfo;
        emit InterestAccrued(_token, tokenInfo.borrowIndex);
        return tokenInfo.borrowIndex;
    }

    /// @notice calculate adjusted fee rate
    /// fee is increased or decreased based on action's effect to pool amount
    /// each token has their target weight set by gov
    /// if action make the weight of token far from its target, fee will be increase, vice versa
    function _calcAdjustedFee(
        uint256 _poolValue,
        address _token,
        uint256 _tokenPrice,
        uint256 _valueChange,
        bool _isSwapIn
    )
        internal
        view
        returns (uint256)
    {
        if (_poolValue == 0) {
            return 0;
        }
        uint256 targetValue = (targetWeights[_token] * _poolValue) / totalWeight;
        uint256 currentValue = _tokenPrice * poolTokens[_token].poolBalance;
        if (currentValue == 0) {
            return 0;
        }
        uint256 nextValue = _isSwapIn ? currentValue + _valueChange : currentValue - _valueChange;
        (uint256 baseSwapFee, uint256 taxBasisPoint) =
            isStableCoin[_token]
            ? (fee.stableCoinBaseSwapFee, fee.stableCoinTaxBasisPoint)
            : (fee.baseSwapFee, fee.taxBasisPoint);
        return _calcAdjustedFee(targetValue, currentValue, nextValue, baseSwapFee, taxBasisPoint);
    }

    function _calcAdjustedFee(
        uint256 _targetValue,
        uint256 _currentValue,
        uint256 _nextValue,
        uint256 _baseSwapFee,
        uint256 _taxBasisPoint
    )
        internal
        pure
        returns (uint256)
    {
        if (_currentValue == 0) {
            return 0;
        } // no fee on initial deposit
        uint256 initDiff = MathUtils.diff(_currentValue, _targetValue);
        uint256 nextDiff = MathUtils.diff(_nextValue, _targetValue);
        if (nextDiff < initDiff) {
            uint256 feeAdjust = _targetValue > 0 ? (_taxBasisPoint * initDiff) / _targetValue : _baseSwapFee;
            return _baseSwapFee > feeAdjust ? _baseSwapFee - feeAdjust : 0;
        } else {
            uint256 avgDiff = (initDiff + nextDiff) / 2;
            uint256 feeAdjust =
                (_targetValue == 0 || avgDiff > _targetValue) ? _taxBasisPoint : (_taxBasisPoint * avgDiff) / _targetValue;
            return _baseSwapFee + feeAdjust;
        }
    }

    /// @notice calculate new avg entry price when increase position
    /// @dev for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    ///      for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    function _calcAveragePrice(
        Side _side,
        uint256 _lastSize,
        uint256 _increasedSize,
        uint256 _entryPrice,
        uint256 _nextPrice
    )
        internal
        pure
        returns (uint256)
    {
        if (_lastSize == 0) {
            return _nextPrice;
        }
        SignedInt memory pnl = PositionUtils.calcPnl(_side, _lastSize, _entryPrice, _nextPrice);
        SignedInt memory nextSize = SignedIntOps.wrap(_lastSize + _increasedSize);
        SignedInt memory divisor = _side == Side.LONG ? nextSize.add(pnl) : nextSize.sub(pnl);
        return nextSize.mul(_nextPrice).div(divisor).toUint();
    }

    function _getPoolValue() internal view returns (uint256 sum) {
        sum = 0;
        for (uint256 i = 0; i < allTranches.length; i++) {
            sum += _getTrancheValue(allTranches[i]);
        }
    }

    function _getTrancheValue(address _tranche) internal view returns (uint256 sum) {
        SignedInt memory aum = SignedIntOps.wrap(uint256(0));

        for (uint256 i = 0; i < allAssets.length; i++) {
            address token = allAssets[i];
            assert(isAsset[token]); // double check
            AssetInfo memory asset = trancheAssets[_tranche][token];
            uint256 price = _getPrice(token);
            if (isStableCoin[token]) {
                aum = aum.add(price * asset.poolAmount);
            } else {
                aum = aum.add(_calcManagedValue(token, asset, price));
            }
        }

        // aum MUST not be negative. If it is, please debug
        return aum.toUint();
    }

    function _calcManagedValue(address _token, AssetInfo memory _asset, uint256 _price)
        internal
        view
        returns (SignedInt memory aum)
    {
        uint256 averageShortPrice = poolTokens[_token].averageShortPrice;
        SignedInt memory shortPnl =
            _asset.totalShortSize == 0
            ? SignedIntOps.wrap(uint256(0))
            : SignedIntOps.wrap(averageShortPrice).sub(_price).mul(_asset.totalShortSize).div(averageShortPrice);

        aum = SignedIntOps.wrap(_asset.poolAmount).sub(_asset.reservedAmount).mul(_price).add(_asset.guaranteedValue);
        aum = aum.sub(shortPnl);
    }

    function _decreaseTranchePoolAmount(address _tranche, address _token, uint256 _amount) internal {
        AssetInfo memory asset = trancheAssets[_tranche][_token];
        asset.poolAmount -= _amount;
        if (asset.poolAmount < asset.reservedAmount) {
            revert PoolErrors.InsufficientPoolAmount(_token);
        }
        trancheAssets[_tranche][_token] = asset;
    }

    /// @notice return pseudo pool asset by sum all tranches asset
    function _getPoolAsset(address _token) internal view returns (AssetInfo memory asset) {
        for (uint256 i = 0; i < allTranches.length; i++) {
            address tranche = allTranches[i];
            asset.poolAmount += trancheAssets[tranche][_token].poolAmount;
            asset.reservedAmount += trancheAssets[tranche][_token].reservedAmount;
            asset.totalShortSize += trancheAssets[tranche][_token].totalShortSize;
            asset.guaranteedValue += trancheAssets[tranche][_token].guaranteedValue;
        }
    }

    /// @notice reserve asset when open position
    function _reservePoolAsset(
        bytes32 _key,
        IncreasePositionVars memory _vars,
        address _indexToken,
        address _collateralToken,
        Side _side
    )
        internal
    {
        AssetInfo memory collateral = _getPoolAsset(_collateralToken);
        AssetInfo memory indexAsset = _getPoolAsset(_indexToken);

        if (collateral.reservedAmount + _vars.reserveAdded > collateral.poolAmount) {
            revert PoolErrors.InsufficientPoolAmount(_collateralToken);
        }

        poolTokens[_collateralToken].feeReserve += _vars.daoFee;
        _reserveTrancheAsset(_key, _vars, _indexToken, _collateralToken, _side);

        if (_side == Side.SHORT) {
            // recalculate total short position
            uint256 lastSize = indexAsset.totalShortSize;
            uint256 entryPrice = poolTokens[_indexToken].averageShortPrice;
            poolTokens[_indexToken].averageShortPrice =
                _calcAveragePrice(Side.SHORT, lastSize, _vars.sizeChanged, entryPrice, _vars.indexPrice);
        }
    }

    /// @notice release asset and take or distribute realized PnL when close position
    function _releasePoolAsset(
        bytes32 _key,
        DecreasePositionVars memory _vars,
        address _indexToken,
        address _collateralToken,
        Side _side
    )
        internal
    {
        AssetInfo memory collateral = _getPoolAsset(_collateralToken);

        if (collateral.reservedAmount < _vars.reserveReduced) {
            revert PoolErrors.ReserveReduceTooMuch(_collateralToken);
        }

        poolTokens[_collateralToken].feeReserve += _vars.daoFee;
        _releaseTranchesAsset(_key, _vars, _indexToken, _collateralToken, _side);
    }

    function _reserveTrancheAsset(
        bytes32 _key,
        IncreasePositionVars memory _vars,
        address _indexToken,
        address _collateralToken,
        Side _side
    )
        internal
    {
        uint256[] memory shares;
        uint256 totalShare;
        if (_vars.reserveAdded > 0) {
            totalShare = _vars.reserveAdded;
            shares = _calcTrancheSharesAmount(_collateralToken, _vars.reserveAdded, false);
        } else {
            totalShare = _vars.collateralAmount;
            shares = _calcTrancheSharesAmount(_collateralToken, _vars.collateralAmount, true);
        }

        for (uint256 i = 0; i < shares.length; i++) {
            address tranche = allTranches[i];
            uint256 share = shares[i];

            AssetInfo storage collateral = trancheAssets[tranche][_collateralToken];
            AssetInfo storage indexAsset = trancheAssets[tranche][_indexToken];

            uint256 reserveAmount = MathUtils.frac(_vars.reserveAdded, share, totalShare);
            tranchePositionReserves[tranche][_key] += reserveAmount;
            collateral.reservedAmount += reserveAmount;

            if (_side == Side.LONG) {
                collateral.poolAmount = collateral.poolAmount
                    + MathUtils.frac(_vars.collateralAmount, share, totalShare)
                    - MathUtils.frac(_vars.daoFee, share, totalShare);
                // ajust guaranteed
                collateral.guaranteedValue = collateral.guaranteedValue
                    + MathUtils.frac(_vars.sizeChanged + _vars.feeValue, share, totalShare)
                    - MathUtils.frac(_vars.collateralValueAdded, share, totalShare);
            } else {
                // recalculate total short position
                indexAsset.totalShortSize += MathUtils.frac(_vars.sizeChanged, share, totalShare);
            }
        }
    }

    function _releaseTranchesAsset(
        bytes32 _key,
        DecreasePositionVars memory _vars,
        address _indexToken,
        address _collateralToken,
        Side _side
    )
        internal
    {
        uint256 totalShare = positions[_key].reserveAmount;

        for (uint256 i = 0; i < allTranches.length; i++) {
            address tranche = allTranches[i];
            uint256 share = tranchePositionReserves[tranche][_key];
            AssetInfo storage collateral = trancheAssets[tranche][_collateralToken];
            AssetInfo storage indexAsset = trancheAssets[tranche][_indexToken];

            {
                uint256 reserveReduced = MathUtils.frac(_vars.reserveReduced, share, totalShare);
                tranchePositionReserves[tranche][_key] -= reserveReduced;
                collateral.reservedAmount -= reserveReduced;
            }
            collateral.poolAmount =
                SignedIntOps.wrap(collateral.poolAmount).sub(_vars.poolAmountReduced.frac(share, totalShare)).toUint();

            if (_side == Side.LONG) {
                collateral.guaranteedValue =
                    collateral.guaranteedValue + MathUtils.frac(_vars.collateralReduced, share, totalShare);
                collateral.guaranteedValue =
                    collateral.guaranteedValue < MathUtils.frac(_vars.sizeChanged, share, totalShare)
                    ? 0
                    : collateral.guaranteedValue - MathUtils.frac(_vars.sizeChanged, share, totalShare);
            } else {
                // fix rounding error when increase total short size
                indexAsset.totalShortSize =
                    MathUtils.zeroCapSub(indexAsset.totalShortSize, MathUtils.frac(_vars.sizeChanged, share, totalShare));
            }
            emit PnLDistributed(_collateralToken, tranche, _vars.pnl.frac(share, totalShare).abs, _vars.pnl.isPos());
        }
    }

    /// @notice distributed amount of token to all tranches
    /// @param _isIncreasePoolAmount set to true when "increase pool amount" or "decrease reserve amount"
    function _calcTrancheSharesAmount(address _token, uint256 _amount, bool _isIncreasePoolAmount)
        internal
        view
        returns (uint256[] memory reserves)
    {
        uint256 nTranches = allTranches.length;
        reserves = new uint[](nTranches);
        uint256[] memory factors = new uint[](nTranches);
        uint256[] memory maxShare = new uint[](nTranches);

        for (uint256 i = 0; i < nTranches; i++) {
            address tranche = allTranches[i];
            AssetInfo memory asset = trancheAssets[tranche][_token];
            factors[i] = riskFactor[_token][tranche];
            maxShare[i] = _isIncreasePoolAmount ? type(uint256).max : asset.poolAmount - asset.reservedAmount;
        }

        uint256 totalFactor = totalRiskFactor[_token];

        for (uint256 k = 0; k < nTranches; k++) {
            uint256 remaining = _amount; // amount distributed in this round

            uint256 totalRiskFactor_ = totalFactor;
            for (uint256 i = 0; i < nTranches; i++) {
                uint256 riskFactor_ = factors[i];
                uint256 shareAmount = MathUtils.frac(remaining, riskFactor_, totalRiskFactor_);
                uint256 availableAmount = maxShare[i] - reserves[i];
                if (shareAmount >= availableAmount) {
                    // skip this tranche on next rounds since it's full
                    shareAmount = availableAmount;
                    totalFactor -= riskFactor_;
                    factors[i] = 0;
                }

                reserves[i] += shareAmount;
                _amount -= shareAmount;
                remaining -= shareAmount;
                totalRiskFactor_ -= riskFactor_;
                if (remaining == 0) {
                    return reserves;
                }
            }
        }

        if (_amount > 0) {
            revert PoolErrors.CannotDistributeToTranches(_token, _amount, _isIncreasePoolAmount);
        }
    }

    /// @notice rebalance fund between tranches after swap token
    function _rebalanceTranches(address _tokenIn, uint256 _amountIn, address _tokenOut, uint256 _amountOut) internal {
        uint256[] memory shares;
        shares = _calcTrancheSharesAmount(_tokenIn, _amountIn, true);
        for (uint256 i = 0; i < shares.length; i++) {
            address tranche = allTranches[i];
            trancheAssets[tranche][_tokenIn].poolAmount += shares[i];
        }

        shares = _calcTrancheSharesAmount(_tokenOut, _amountOut, false);
        for (uint256 i = 0; i < shares.length; i++) {
            address tranche = allTranches[i];
            // always safe
            trancheAssets[tranche][_tokenOut].poolAmount -= shares[i];
        }
    }

    function _liquidatePositionAllowed(Position memory _position, Side _side, uint256 _indexPrice, uint256 _borrowIndex)
        internal
        view
        returns (bool allowed)
    {
        if (_position.size == 0) {
            return false;
        }
        // calculate fee needed when close position
        uint256 feeValue = _calcPositionFee(_position, _position.size, _borrowIndex);
        feeValue = feeValue + fee.liquidationFee;
        SignedInt memory pnl = PositionUtils.calcPnl(_side, _position.size, _position.entryPrice, _indexPrice);
        SignedInt memory remainingCollateral = pnl.add(_position.collateralValue).sub(feeValue);
        return !remainingCollateral.isPos() || remainingCollateral.abs * maxLeverage < _position.size;
    }

    function _calcDecreasePayout(
        Position memory _position,
        address _indexToken,
        address _collateralToken,
        Side _side,
        uint256 _sizeChanged,
        uint256 _collateralChanged
    )
        internal
        view
        returns (DecreasePositionVars memory vars)
    {
        // clean user input
        vars.sizeChanged = _position.size < _sizeChanged ? _position.size : _sizeChanged;
        vars.collateralReduced =
            _position.collateralValue < _collateralChanged || _position.size == _sizeChanged
            ? _position.collateralValue
            : _collateralChanged;

        vars.indexPrice = _getPrice(_indexToken);
        vars.collateralPrice = _getPrice(_collateralToken);

        uint256 borrowIndex = poolTokens[_collateralToken].borrowIndex;

        // vars is santinized, only trust these value from now on
        vars.reserveReduced = (_position.reserveAmount * vars.sizeChanged) / _position.size;
        vars.pnl = PositionUtils.calcPnl(_side, vars.sizeChanged, _position.entryPrice, vars.indexPrice);
        vars.feeValue = _calcPositionFee(_position, vars.sizeChanged, borrowIndex);
        vars.daoFee = vars.feeValue * fee.daoFee / vars.collateralPrice / FEE_PRECISION;

        SignedInt memory remainingCollateral = SignedIntOps.wrap(_position.collateralValue).sub(vars.collateralReduced);
        SignedInt memory payoutValue = vars.pnl.add(vars.collateralReduced).sub(vars.feeValue);
        if (payoutValue.isNeg()) {
            // deduct uncovered lost from collateral
            remainingCollateral = remainingCollateral.add(payoutValue);
            payoutValue = SignedIntOps.wrap(uint256(0));
        }

        vars.remainingCollateral = remainingCollateral.isNeg() ? 0 : remainingCollateral.abs;
        vars.payout = payoutValue.isNeg() ? 0 : payoutValue.abs / vars.collateralPrice;
        SignedInt memory poolValueReduced = _side == Side.LONG ? payoutValue.add(vars.feeValue) : vars.pnl;
        vars.poolAmountReduced = poolValueReduced.div(vars.collateralPrice);
    }

    function _calcPositionFee(Position memory _position, uint256 _sizeChanged, uint256 _borrowIndex)
        internal
        view
        returns (uint256 feeValue)
    {
        uint256 borrowFee = ((_borrowIndex - _position.borrowIndex) * _position.size) / INTEREST_RATE_PRECISION;
        uint256 positionFee = (_sizeChanged * fee.positionFee) / FEE_PRECISION;
        feeValue = borrowFee + positionFee;
    }

    function _getPrice(address _token) internal view returns (uint256) {
        return oracle.getPrice(_token);
    }
}
