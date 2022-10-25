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
import {IOracle} from "../interfaces/IOracle.sol";
import {ILPToken} from "../interfaces/ILPToken.sol";
import {IPool, Side, TokenWeight} from "../interfaces/IPool.sol";
import {LPToken} from "../tokens/LPToken.sol";
import {
    PoolStorage,
    Position,
    PoolAsset,
    Fee,
    INTEREST_RATE_PRECISION,
    FEE_PRECISION,
    LP_INITIAL_PRICE,
    MAX_BASE_SWAP_FEE,
    MAX_TAX_BASIS_POINT,
    MAX_POSITION_FEE
} from "./PoolStorage.sol";
import {PoolErrors} from "./PoolErrors.sol";
import {IPositionHook} from "../interfaces/IPositionHook.sol";

using SignedIntOps for SignedInt;
using UniERC20 for IERC20;
using SafeERC20 for IERC20;

struct IncreasePositionVars {
    uint256 reserveAdded;
    uint256 collateralAmount;
    uint256 collateralValueAdded;
    uint256 feeValue;
    uint256 feeAmount;
    uint256 indexPrice;
}

struct DecreasePositionVars {
    uint256 collateralValue;
    uint256 reserveReduced;
    uint256 feeValue;
    uint256 feeAmount;
    uint256 payout;
    uint256 indexPrice;
    uint256 collateralPrice;
    uint256 collateralChanged;
    uint256 sizeChanged;
    SignedInt pnl;
}

struct PositionView {
    bytes32 key;
    uint256 size;
    uint256 collateralValue;
    uint256 entryPrice;
    uint256 pnl;
    uint256 reserveAmount;
    bool hasProfit;
    address collateralToken;
    uint256 borrowIndex;
}

contract Pool is Initializable, PoolStorage, OwnableUpgradeable, ReentrancyGuardUpgradeable, IPool {
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
    }

    // ========= View functions  =========
    function validateToken(address _indexToken, address _collateralToken, Side _side, bool _isIncrease)
        external
        view
        returns (bool)
    {
        return _validateToken(_indexToken, _collateralToken, _side, _isIncrease);
    }

    function getPosition(address _owner, address _indexToken, address _collateralToken, Side _side)
        external
        view
        returns (PositionView memory result)
    {
        bytes32 positionKey = _getPositionKey(_owner, _indexToken, _collateralToken, _side);
        Position memory position = positions[positionKey];
        uint256 indexPrice = _getPrice(_indexToken);
        SignedInt memory pnl = _calcPnl(_side, position.size, position.entryPrice, indexPrice);

        result.key = positionKey;
        result.size = position.size;
        result.collateralValue = position.collateralValue;
        result.pnl = pnl.abs;
        result.hasProfit = pnl.gt(uint256(0));
        result.entryPrice = position.entryPrice;
        result.borrowIndex = position.borrowIndex;
        result.reserveAmount = position.reserveAmount;
        result.collateralToken = _collateralToken;
    }

    function getPoolValue() external view returns (uint256 sum) {
        return _getPoolValue();
    }

    function getTrancheValue(address _tranche) external view returns (uint256 sum) {
        if (!isTranche[_tranche]) {
            revert PoolErrors.InvalidTranche(_tranche);
        }
        return _calcTrancheValue(_tranche);
    }

    function getLpPrice(address _tranche) external view returns (uint256) {
        if (!isTranche[_tranche]) {
            revert PoolErrors.InvalidTranche(_tranche);
        }

        uint256 lpSupply = ILPToken(_tranche).totalSupply();
        return lpSupply == 0 ? LP_INITIAL_PRICE : _calcTrancheValue(_tranche) / lpSupply;
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

        (uint256 amountInAfterFee, uint256 feeAmount, uint256 lpAmount) = _calcAddLiquidity(_tranche, _token, _amountIn);
        if (lpAmount < _minLpAmount) {
            revert PoolErrors.SlippageExceeded();
        }

        PoolAsset storage asset = poolAssets[_token];
        asset.feeReserve += feeAmount;
        asset.poolAmount += amountInAfterFee;
        asset.liquidity += amountInAfterFee;
        asset.poolBalance = IERC20(_token).getBalance(address(this));
        tranchePoolBalance[_token][_tranche] += amountInAfterFee;

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

        uint256 trancheBalance = tranchePoolBalance[_tokenOut][_tranche];
        if (trancheBalance < outAmount) {
            revert PoolErrors.RemoveLiquidityTooMuch(_tranche, outAmount, trancheBalance);
        }
        tranchePoolBalance[_tokenOut][_tranche] = trancheBalance - outAmount;
        poolAssets[_tokenOut].feeReserve += feeAmount;
        poolAssets[_tokenOut].liquidity -= outAmountAfterFee;
        _decreasePoolAmount(_tokenOut, outAmountAfterFee);

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
        uint256 amountIn = _getAmountIn(_tokenIn, true);
        if (amountIn == 0) {
            revert PoolErrors.ZeroAmount();
        }
        (uint256 amountOut, uint256 swapFee) = _calcSwapOutput(_tokenIn, _tokenOut, amountIn);
        uint256 amountOutAfterFee = amountOut - swapFee;
        if (amountOutAfterFee < _minOut) {
            revert PoolErrors.SlippageExceeded();
        }
        poolAssets[_tokenIn].poolAmount += amountIn;
        poolAssets[_tokenOut].feeReserve += swapFee;
        _decreasePoolAmount(_tokenOut, amountOut - swapFee);
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
        vars.collateralAmount = _getAmountIn(_collateralToken, true);
        if (vars.collateralAmount == 0) {
            revert PoolErrors.ZeroAmount();
        }
        vars.collateralValueAdded = collateralPrice * vars.collateralAmount;

        // update position
        vars.feeValue = _calcPositionFee(position, _sizeChanged, borrowIndex);
        vars.feeAmount = vars.feeValue / collateralPrice;
        vars.reserveAdded = _sizeChanged / collateralPrice;
        position.entryPrice =
            _calcAveragePrice(_side, position.size, _sizeChanged, position.entryPrice, vars.indexPrice);
        position.collateralValue =
            MathUtils.zeroCapSub(position.collateralValue + vars.collateralValueAdded, vars.feeValue);
        position.size = position.size + _sizeChanged;
        position.borrowIndex = borrowIndex;
        position.reserveAmount += vars.reserveAdded;
        _validatePosition(position, _collateralToken, _side, true, vars.indexPrice);

        // upate pool assets
        _reservePoolAsset(vars, _indexToken, _collateralToken, _side, _sizeChanged);
        positions[key] = position;

        emit IncreasePosition(
            key,
            _owner,
            _collateralToken,
            _indexToken,
            vars.collateralAmount,
            _sizeChanged,
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
            _calculateDecreasePayout(position, _indexToken, _collateralToken, _side, _sizeChanged, _collateralChanged);

        position.size = position.size - vars.sizeChanged;
        position.borrowIndex = borrowIndex;
        position.reserveAmount = position.reserveAmount - vars.reserveReduced;
        uint256 collateralReduced = position.collateralValue - vars.collateralValue;
        position.collateralValue = vars.collateralValue;

        _validatePosition(position, _collateralToken, _side, false, vars.indexPrice);
        _releasePoolAsset(vars, _indexToken, _collateralToken, _side, 0);

        emit DecreasePosition(
            key,
            _owner,
            _collateralToken,
            _indexToken,
            collateralReduced,
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
        _accrueInterest(_collateralToken);
        bytes32 key = _getPositionKey(_account, _indexToken, _collateralToken, _side);
        Position memory position = positions[key];
        if (address(positionHook) != address(0)) {
            positionHook.preDecreasePosition(_account, _indexToken, _collateralToken, _side, position.size, bytes(""));
        }
        DecreasePositionVars memory vars = _calculateDecreasePayout(
            position, _indexToken, _collateralToken, _side, position.size, position.collateralValue
        );

        if (vars.collateralValue > fee.liquidationFee) {
            revert PoolErrors.PositionNotLiquidated(key);
        }
        uint256 liquidationFee = fee.liquidationFee / vars.collateralPrice;
        _releasePoolAsset(vars, _indexToken, _collateralToken, _side, liquidationFee);

        emit LiquidatePosition(
            key,
            _account,
            _collateralToken,
            _indexToken,
            _side,
            position.size,
            position.collateralValue - vars.collateralValue,
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
    function addTranche(address _tranche, uint256 _share) external onlyOwner {
        if (_tranche == address(0)) {
            revert PoolErrors.ZeroAddress();
        }
        if (isTranche[_tranche]) {
            revert PoolErrors.TrancheAlreadyAdded(_tranche);
        }
        isTranche[_tranche] = true;
        trancheShares[_tranche] = _share;
        totalTrancheShare += _share;
        _pushUnique(allTranches, _tranche);
        emit TrancheAdded(_tranche, _share, totalTrancheShare);
    }

    function setTrancheShare(address _tranche, uint256 _share) external onlyOwner {
        if (!isTranche[_tranche]) {
            revert PoolErrors.InvalidTranche(_tranche);
        }

        totalTrancheShare = totalTrancheShare + _share - trancheShares[_tranche];
        trancheShares[_tranche] = _share;
        emit TrancheUpdated(_tranche, _share, totalTrancheShare);
    }

    function addToken(address _token, bool _isStableCoin) external onlyOwner {
        if (isAsset[_token]) {
            revert PoolErrors.DuplicateToken(_token);
        }
        isAsset[_token] = true;
        isListed[_token] = true;
        _pushUnique(allAssets, _token);
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
        if (_baseSwapFee > MAX_BASE_SWAP_FEE || _stableCoinBaseSwapFee > MAX_BASE_SWAP_FEE) {
            revert PoolErrors.ValueTooHigh(MAX_BASE_SWAP_FEE);
        }
        if (_taxBasisPoint > MAX_TAX_BASIS_POINT || _stableCoinTaxBasisPoint > MAX_TAX_BASIS_POINT) {
            revert PoolErrors.ValueTooHigh(MAX_TAX_BASIS_POINT);
        }
        fee.baseSwapFee = _baseSwapFee;
        fee.taxBasisPoint = _taxBasisPoint;
        fee.stableCoinBaseSwapFee = _stableCoinBaseSwapFee;
        fee.stableCoinTaxBasisPoint = _stableCoinTaxBasisPoint;
        emit SwapFeeSet(_baseSwapFee, _taxBasisPoint, _stableCoinBaseSwapFee, _stableCoinTaxBasisPoint);
    }

    function setPositionFee(uint256 _positionFee, uint256 _liquidationFee) external onlyOwner {
        if (_positionFee > MAX_POSITION_FEE) {
            revert PoolErrors.ValueTooHigh(MAX_POSITION_FEE);
        }
        fee.positionFee = _positionFee;
        fee.liquidationFee = _liquidationFee;
        emit PositionFeeSet(_positionFee, _liquidationFee);
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
        if (msg.sender != feeDistributor) {
            revert PoolErrors.FeeDistributorOnly();
        }
        uint256 amount = poolAssets[_token].feeReserve;
        poolAssets[_token].feeReserve = 0;
        _doTransferOut(_token, _recipient, amount);
        emit FeeWithdrawn(_token, _recipient, amount);
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
        uint256 poolValue = _calcTrancheValue(_tranche);
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
        uint256 poolValue = _calcTrancheValue(_tranche);
        uint256 totalSupply = ILPToken(_tranche).totalSupply();
        uint256 valueChange = (_lpAmount * poolValue) / totalSupply;
        uint256 _fee = _calcAdjustedFee(poolValue, _tokenOut, tokenPrice, valueChange, true);
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
        return _getAmountIn(_token, false);
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

        uint256 borrowIndex = poolAssets[_collateralToken].borrowIndex;
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

    function _getAmountIn(address _token, bool _update) internal returns (uint256 amount) {
        uint256 balance = IERC20(_token).getBalance(address(this));
        amount = balance - poolAssets[_token].poolBalance;
        if (_update) {
            poolAssets[_token].poolBalance = balance;
        }
    }

    function _doTransferOut(address _token, address _to, uint256 _amount) internal {
        if (_amount > 0) {
            IERC20 token = IERC20(_token);
            token.transferTo(_to, _amount);
            poolAssets[_token].poolBalance = token.getBalance(address(this));
        }
    }

    function _accrueInterest(address _token) internal returns (uint256) {
        PoolAsset memory asset = poolAssets[_token];
        uint256 _now = block.timestamp;
        if (asset.lastAccrualTimestamp == 0) {
            // accrue interest for the first time
            asset.lastAccrualTimestamp = (_now / accrualInterval) * accrualInterval;
        } else {
            uint256 nInterval = (_now - asset.lastAccrualTimestamp) / accrualInterval;
            if (nInterval == 0) {
                return asset.borrowIndex;
            }

            asset.borrowIndex = asset.borrowIndex + (nInterval * interestRate * asset.reservedAmount) / asset.poolAmount;
            asset.lastAccrualTimestamp += nInterval * accrualInterval;
        }

        poolAssets[_token] = asset;
        emit InterestAccrued(_token, asset.borrowIndex);
        return asset.borrowIndex;
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
        uint256 currentValue = _tokenPrice * poolAssets[_token].poolBalance;
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
        SignedInt memory pnl = _calcPnl(_side, _lastSize, _entryPrice, _nextPrice);
        SignedInt memory nextSize = SignedIntOps.wrap(_lastSize + _increasedSize);
        SignedInt memory divisor = _side == Side.LONG ? nextSize.add(pnl) : nextSize.sub(pnl);
        return nextSize.mul(_nextPrice).div(divisor).toUint();
    }

    function _calcPnl(Side _side, uint256 _positionSize, uint256 _entryPrice, uint256 _indexPrice)
        public
        pure
        returns (SignedInt memory)
    {
        if (_positionSize == 0) {
            return SignedIntOps.wrap(uint256(0));
        }
        if (_side == Side.LONG) {
            return SignedIntOps.wrap(_indexPrice).sub(_entryPrice).mul(_positionSize).div(_entryPrice);
        } else {
            return SignedIntOps.wrap(_entryPrice).sub(_indexPrice).mul(_positionSize).div(_entryPrice);
        }
    }

    function _getPoolValue() internal view returns (uint256 sum) {
        SignedInt memory aum = SignedIntOps.wrap(uint256(0));

        for (uint256 i = 0; i < allAssets.length; i++) {
            address token = allAssets[i];
            assert(isAsset[token]); // double check
            PoolAsset memory asset = poolAssets[token];
            uint256 price = _getPrice(token);
            if (isStableCoin[token]) {
                aum = aum.add(price * asset.poolAmount);
            } else {
                aum = aum.add(_calcManagedValue(asset, price));
            }
        }

        // aum MUST not be negative. If it is, please debug
        return aum.toUint();
    }

    function _calcManagedValue(PoolAsset memory _asset, uint256 _price) internal pure returns (SignedInt memory aum) {
        SignedInt memory shortPnl =
            _asset.totalShortSize == 0
            ? SignedIntOps.wrap(uint256(0))
            : SignedIntOps.wrap(_asset.averageShortPrice).sub(_price).mul(_asset.totalShortSize).div(_asset.averageShortPrice);

        aum = SignedIntOps.wrap(_asset.poolAmount).sub(_asset.reservedAmount).mul(_price).add(_asset.guaranteedValue);
        aum = aum.sub(shortPnl);
    }

    function _calcTrancheValue(address _tranche) internal view returns (uint256) {
        SignedInt memory aum = SignedIntOps.wrap(uint256(0));
        uint256 trancheShare = trancheShares[_tranche];

        for (uint256 i = 0; i < allAssets.length; i++) {
            address token = allAssets[i];
            assert(isAsset[token]); // double check
            uint256 price = _getPrice(token);
            PoolAsset memory asset = poolAssets[token];
            uint256 tokenBalanceInTranche = tranchePoolBalance[token][_tranche];
            if (isStableCoin[token]) {
                aum = aum.add(price * tokenBalanceInTranche);
            } else {
                SignedInt memory tranchePnl = _calcTranchePnl(asset, price, trancheShare);
                aum = aum.add(price * tokenBalanceInTranche).sub(tranchePnl);
            }
        }

        return aum.isNeg() ? 0 : aum.toUint();
    }

    function _calcTranchePnl(PoolAsset memory _asset, uint256 _price, uint256 _trancheShare)
        internal
        view
        returns (SignedInt memory)
    {
        SignedInt memory aum = _calcManagedValue(_asset, _price);
        // uint assetBalance = _asset.poolBalance - _asset.feeReserve;
        // AUM = user deposited value - positions' PnL
        // => PnL = deposited value - aum
        // PnL is distributed to tranche by its share
        return SignedIntOps.wrap((_asset.liquidity) * _price).sub(aum).mul(_trancheShare).div(totalTrancheShare);
    }

    function _decreasePoolAmount(address _token, uint256 _amount) internal {
        PoolAsset memory asset = poolAssets[_token];
        asset.poolAmount -= _amount;
        if (asset.poolAmount < asset.reservedAmount) {
            revert PoolErrors.InsufficientPoolAmount(_token);
        }
        poolAssets[_token] = asset;
    }

    /// @notice reserve asset when open position
    function _reservePoolAsset(
        IncreasePositionVars memory _vars,
        address _indexToken,
        address _collateralToken,
        Side _side,
        uint256 _sizeChanged
    )
        internal
    {
        PoolAsset storage collateral = poolAssets[_collateralToken];
        PoolAsset storage indexAsset = poolAssets[_indexToken];

        collateral.reservedAmount += _vars.reserveAdded;
        if (collateral.reservedAmount > collateral.poolAmount) {
            revert PoolErrors.InsufficientPoolAmount(_collateralToken);
        }
        collateral.feeReserve += _vars.feeAmount;

        if (_side == Side.LONG) {
            collateral.poolAmount = collateral.poolAmount + _vars.collateralAmount - _vars.feeAmount;
            // ajust guaranteed
            collateral.guaranteedValue =
                collateral.guaranteedValue + _sizeChanged + _vars.feeValue - _vars.collateralValueAdded;
        } else {
            // recalculate total short position
            uint256 lastSize = indexAsset.totalShortSize;
            uint256 entryPrice = indexAsset.averageShortPrice;
            indexAsset.averageShortPrice =
                _calcAveragePrice(Side.SHORT, lastSize, _sizeChanged, entryPrice, _vars.indexPrice);
            indexAsset.totalShortSize = lastSize + _sizeChanged;
        }
    }

    /// @notice release asset and take or distribute realized PnL when close position
    /// @param _liquidationFee set to 0 when close position
    function _releasePoolAsset(
        DecreasePositionVars memory _vars,
        address _indexToken,
        address _collateralToken,
        Side _side,
        uint256 _liquidationFee
    )
        internal
    {
        PoolAsset storage collateral = poolAssets[_collateralToken];
        PoolAsset storage indexAsset = poolAssets[_indexToken];

        if (collateral.reservedAmount < _vars.reserveReduced) {
            revert PoolErrors.ReserveReduceTooMuch(_collateralToken);
        }

        SignedInt memory netPnL = _vars.pnl.div(_vars.collateralPrice).sub(_vars.feeAmount + _liquidationFee);
        _distributePnL(_collateralToken, netPnL);

        collateral.liquidity = netPnL.isNeg() ? collateral.liquidity + netPnL.abs : collateral.liquidity - netPnL.abs;
        collateral.reservedAmount -= _vars.reserveReduced;
        collateral.feeReserve += _vars.feeAmount;

        if (_side == Side.LONG) {
            collateral.guaranteedValue = collateral.guaranteedValue + _vars.collateralChanged - _vars.sizeChanged;
            collateral.poolAmount -= _vars.payout + _vars.feeAmount + _liquidationFee;
        } else {
            indexAsset.totalShortSize -= _vars.sizeChanged;
        }
    }

    /// @notice distribute position realized PnL to trache
    /// When user lost, their collateral simply added to tranche balance by share of each tranche
    /// When user win, token from each tranche is removed by their share or their balance
    function _distributePnL(address _token, SignedInt memory _pnl) internal {
        // tranche balance increased when user lost, vice versa
        (bool increase, uint256 amount) = (_pnl.isNeg(), _pnl.abs);
        uint256 totalShare = totalTrancheShare;
        uint256[] memory distributed = new uint256[](allTranches.length);
        for (uint256 k = 0; k < allTranches.length; k++) {
            uint256 distributedAmount = 0;
            for (uint256 i = 0; i < allTranches.length; i++) {
                // in each route we devide amount to tranche by its share, until nothing left
                address tranche = allTranches[i];
                uint256 trancheBalance = tranchePoolBalance[_token][tranche];
                uint256 shareAmount = amount * trancheShares[tranche] / totalShare;
                if (increase) {
                    trancheBalance += shareAmount;
                    distributedAmount += shareAmount;
                    distributed[i] = shareAmount;
                } else {
                    if (trancheBalance == 0) {
                        continue;
                    }
                    if (trancheBalance < shareAmount) {
                        shareAmount = trancheBalance;
                        totalShare -= trancheShares[tranche];
                    }
                    trancheBalance -= shareAmount;
                    distributedAmount += shareAmount;
                    distributed[i] += shareAmount;
                }
                tranchePoolBalance[_token][tranche] = trancheBalance;
            }
            amount -= distributedAmount;
            if (amount == 0) {
                break;
            }
        }

        for (uint256 i = 0; i < allTranches.length; i++) {
            emit PnLDistributed(_token, allTranches[i], distributed[i], !increase);
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
        SignedInt memory pnl = _calcPnl(_side, _position.size, _position.entryPrice, _indexPrice);
        SignedInt memory remainingCollateral = pnl.add(_position.collateralValue).sub(feeValue);
        return !remainingCollateral.isPos();
    }

    function _calculateDecreasePayout(
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
        vars.indexPrice = _getPrice(_indexToken);
        vars.collateralPrice = _getPrice(_collateralToken);
        uint256 borrowIndex = poolAssets[_collateralToken].borrowIndex;
        vars.sizeChanged = _position.size < _sizeChanged ? _position.size : _sizeChanged;
        vars.collateralChanged =
            _position.collateralValue < _collateralChanged || _position.size == _sizeChanged
            ? _position.collateralValue
            : _collateralChanged;

        vars.reserveReduced = (_position.reserveAmount * _sizeChanged) / _position.size;
        vars.pnl = _calcPnl(_side, _sizeChanged, _position.entryPrice, vars.indexPrice);

        vars.feeValue = _calcPositionFee(_position, _sizeChanged, borrowIndex);
        vars.feeAmount = vars.feeValue / vars.collateralPrice;
        SignedInt memory payoutValue = vars.pnl.add(_collateralChanged).sub(vars.feeValue);
        SignedInt memory collateral = SignedIntOps.wrap(_position.collateralValue).sub(_collateralChanged);

        if (payoutValue.isNeg()) {
            // deduct uncovered lost from collateral
            collateral = collateral.add(payoutValue);
        }

        vars.collateralValue = collateral.isNeg() ? 0 : collateral.abs;
        vars.payout = payoutValue.isNeg() ? 0 : payoutValue.abs / vars.collateralPrice;
    }

    function _pushUnique(address[] storage _list, address _elem) internal {
        bool exists = false;
        for (uint256 i = 0; i < _list.length; i++) {
            if (_list[i] == _elem) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            _list.push(_elem);
        }
    }

    /// @notice calculate slippage base on oracle price
    /// @param _oraclePrice price get from oracle
    /// @param _notionalImpactSize maximum size to which the price impact is negligible (theoricaly)
    /// @param _tradeSize value to trade
    function _calcAdjustedPrice(
        uint256 _oraclePrice,
        uint256 _notionalImpactSize,
        uint256 _poolAmount,
        uint256 _tradeSize,
        bool _isBuy
    )
        internal
        pure
        returns (uint256)
    {
        if (_tradeSize * _oraclePrice <= _notionalImpactSize) {
            return _oraclePrice;
        }

        uint256 pseudoPooledUsd = _oraclePrice * _poolAmount - _notionalImpactSize;
        return _isBuy ? pseudoPooledUsd / (_poolAmount - _tradeSize) : pseudoPooledUsd / (_poolAmount + _tradeSize);
    }

    function _calcPositionFee(Position memory _position, uint256 _sizeChanged, uint256 _borrowIndex)
        public
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
