// SPDX-License-Identifier: MIT

pragma solidity 0.8.15;

import {ReentrancyGuardUpgradeable} from "openzeppelin-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IPool, Side} from "../interfaces/IPool.sol";
import {SwapOrder, Order} from "../interfaces/IOrderManager.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IOrderHook} from "../interfaces/IOrderHook.sol";
import {UniERC20} from "../lib/UniERC20.sol";

interface IWhitelistedPool {
    // this function declared as mapping
    function whitelistedTokens(address) external returns (bool);
}

enum UpdatePositionType {
    INCREASE,
    DECREASE
}

enum OrderType {
    MARKET,
    LIMIT
}

struct UpdatePositionRequest {
    Side side;
    uint256 sizeChange;
    uint256 collateral;
    UpdatePositionType updateType;
}

contract OrderManager is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using UniERC20 for IERC20;

    uint256 constant MARKET_ORDER_TIMEOUT = 300;

    uint256 public nextOrderId;
    mapping(uint256 => Order) public orders;
    mapping(uint256 => UpdatePositionRequest) public requests;

    uint256 public nextSwapOrderId;
    mapping(uint256 => SwapOrder) public swapOrders;

    mapping(address => bool) public isPool;
    address[] public allPools;
    IOracle public oracle;
    uint256 public minExecutionFee;

    IOrderHook public orderHook;

    receive() external payable {
        // prevent send ETH directly to contract
        if (!isPool[msg.sender]) {
            revert("OrderManager:rejected");
        }
    }

    function initialize(address _oracle, uint256 _minExecutionFee) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        require(_oracle != address(0), "OrderManager:invalidOracle");
        minExecutionFee = _minExecutionFee;
        oracle = IOracle(_oracle);
        nextOrderId = 1;
        nextSwapOrderId = 1;
    }

    function placeOrder(
        IPool _pool,
        UpdatePositionType _updateType,
        Side _side,
        address _indexToken,
        address _collateralToken,
        OrderType _orderType,
        bytes memory data
    ) external payable nonReentrant {
        bool isIncrease = _updateType == UpdatePositionType.INCREASE;
        require(_pool.validateToken(_indexToken, _collateralToken, _side, isIncrease), "OrderManager:invalidTokens");
        if (isIncrease) {
            _createIncreasePositionOrder(_pool, _side, _indexToken, _collateralToken, _orderType, data);
        } else {
            _createDecreasePositionOrder(_pool, _side, _indexToken, _collateralToken, _orderType, data);
        }
    }

    function placeSwapOrder(
        IPool _pool,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _minOut,
        uint256 _price
    ) external payable nonReentrant {
        require(
            IWhitelistedPool(address(_pool)).whitelistedTokens(_tokenIn) &&
                IWhitelistedPool(address(_pool)).whitelistedTokens(_tokenOut),
            "Invalid tokens"
        );

        uint256 executionFee;
        if (_tokenIn == UniERC20.ETH) {
            executionFee = msg.value - _amountIn;
        } else {
            executionFee = msg.value;
            IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);
        }
        require(executionFee >= minExecutionFee, "OrderManager:executionFeeTooLow");

        SwapOrder memory order = SwapOrder({
            pool: _pool,
            owner: msg.sender,
            tokenIn: _tokenIn,
            tokenOut: _tokenOut,
            amountIn: _amountIn,
            minAmountOut: _minOut,
            price: _price,
            executionFee: executionFee
        });
        swapOrders[nextSwapOrderId] = order;
        emit SwapOrderPlaced(nextSwapOrderId);
        nextSwapOrderId += 1;
    }

    function swap(
        IPool _pool,
        address _fromToken,
        address _toToken,
        uint256 _amountIn,
        uint256 _minAmountOut
    ) external payable {
        require(_fromToken != _toToken, "OrderManager:sameToken");
        IERC20 tokenOut = IERC20(_toToken);
        uint256 priorBalance = tokenOut.getBalance(msg.sender);
        _poolSwap(_pool, _fromToken, _toToken, _amountIn, _minAmountOut, msg.sender);
        uint256 amountOut = tokenOut.getBalance(msg.sender) - priorBalance;
        emit Swap(msg.sender, _fromToken, _toToken, address(_pool), _amountIn, amountOut);
    }

    function executeOrder(uint256 _orderId, address payable _feeTo) external nonReentrant {
        Order memory order = orders[_orderId];
        require(order.owner != address(0), "OrderManager:orderNotExists");
        require(isPool[address(order.pool)], "OrderManager:invalidOrPausedPool");
        require(block.number > order.submissionBlock, "OrderManager:blockNotPass");

        if (order.expiresAt > 0 && order.expiresAt < block.timestamp) {
            _expiresOrder(_orderId, order);
            return;
        }

        uint256 indexPrice = oracle.getPrice(order.indexToken);
        bool isValid = order.triggerAboveThreshold ? indexPrice >= order.price : indexPrice <= order.price;
        if (!isValid) {
            if (order.expiresAt > 0) {
                _expiresOrder(_orderId, order);
            }
            return;
        }

        UpdatePositionRequest memory request = requests[_orderId];
        _executeRequest(order, request);
        delete orders[_orderId];
        delete requests[_orderId];
        UniERC20.safeTransferETH(_feeTo, order.executionFee);
        emit OrderExecuted(_orderId, order, request, indexPrice);
    }

    /// @dev omit nonReentrant since all calls (execute single order) is non reentrant themselves
    function executeOrders(uint256[] calldata _orderIds, address payable _feeTo) external {
        for (uint256 i = 0; i < _orderIds.length; i++) {
            try this.executeOrder(_orderIds[i], _feeTo) {} catch {}
        }
    }

    function cancelOrder(uint256 _orderId) external nonReentrant {
        Order memory order = orders[_orderId];
        require(order.owner == msg.sender, "OrderManager:unauthorizedCancellation");
        UpdatePositionRequest memory request = requests[_orderId];

        delete orders[_orderId];
        delete requests[_orderId];

        UniERC20.safeTransferETH(order.owner, order.executionFee);
        if (request.updateType == UpdatePositionType.INCREASE) {
            IERC20(order.collateralToken).transferTo(order.owner, request.collateral);
        }

        emit OrderCancelled(_orderId);
    }

    function cancelSwapOrder(uint256 _orderId) external nonReentrant {
        SwapOrder memory order = swapOrders[_orderId];
        require(order.owner == msg.sender, "OrderManager:unauthorizedCancellation");
        delete swapOrders[_orderId];
        UniERC20.safeTransferETH(order.owner, order.executionFee);
        IERC20(order.tokenIn).transferTo(order.owner, order.amountIn);
        emit SwapOrderCancelled(_orderId);
    }

    function executeSwapOrder(uint256 _orderId, address payable _feeTo) external {
        SwapOrder memory order = swapOrders[_orderId];
        require(order.owner != address(0), "OrderManager:notFound");
        delete swapOrders[_orderId];
        IERC20(order.tokenIn).transferTo(address(order.pool), order.amountIn);
        IERC20 tokenOut = IERC20(order.tokenOut);
        uint256 balance = tokenOut.getBalance(order.owner);
        order.pool.swap(order.tokenIn, order.tokenOut, order.minAmountOut, order.owner);
        uint256 amountOut = tokenOut.getBalance(order.owner) - balance;
        UniERC20.safeTransferETH(_feeTo, order.executionFee);
        emit SwapOrderExecuted(_orderId, order.amountIn, amountOut);
    }

    function _executeRequest(Order memory _order, UpdatePositionRequest memory _request) internal {
        if (_request.updateType == UpdatePositionType.INCREASE) {
            IERC20(_order.collateralToken).transferTo(address(_order.pool), _request.collateral);
            _order.pool.increasePosition(
                _order.owner,
                _order.indexToken,
                _order.collateralToken,
                _request.sizeChange,
                _request.side
            );
        } else {
            IERC20 collateralToken = IERC20(_order.collateralToken);
            uint256 priorBalance = collateralToken.getBalance(address(this));
            _order.pool.decreasePosition(
                _order.owner,
                _order.indexToken,
                _order.collateralToken,
                _request.collateral,
                _request.sizeChange,
                _request.side,
                address(this)
            );
            uint256 payoutAmount = collateralToken.getBalance(address(this)) - priorBalance;
            if (_order.collateralToken != _order.payToken) {
                IERC20(_order.payToken).transferTo(address(_order.pool), payoutAmount);
                _order.pool.swap(_order.collateralToken, _order.payToken, 0, _order.owner);
            } else {
                collateralToken.transferTo(_order.owner, payoutAmount);
            }
        }
    }

    function _createDecreasePositionOrder(
        IPool _pool,
        Side _side,
        address _indexToken,
        address _collateralToken,
        OrderType _orderType,
        bytes memory _data
    ) internal returns (uint256 orderId) {
        Order memory order;
        UpdatePositionRequest memory request;
        bytes memory extradata;

        if (_orderType == OrderType.MARKET) {
            (order.price, order.payToken, request.sizeChange, request.collateral, extradata) = abi.decode(
                _data,
                (uint256, address, uint256, uint256, bytes)
            );
            order.triggerAboveThreshold = _side == Side.LONG;
        } else {
            (
                order.price,
                order.triggerAboveThreshold,
                order.payToken,
                request.sizeChange,
                request.collateral,
                extradata
            ) = abi.decode(_data, (uint256, bool, address, uint256, uint256, bytes));
        }
        order.pool = _pool;
        order.owner = msg.sender;
        order.indexToken = _indexToken;
        order.collateralToken = _collateralToken;
        order.expiresAt = _orderType == OrderType.MARKET ? block.timestamp + MARKET_ORDER_TIMEOUT : 0;
        order.submissionBlock = block.number;
        order.executionFee = msg.value;
        require(order.executionFee >= minExecutionFee, "OrderManager:executionFeeTooLow");

        request.updateType = UpdatePositionType.DECREASE;
        request.side = _side;
        orderId = nextOrderId;
        nextOrderId = orderId + 1;
        orders[orderId] = order;
        requests[orderId] = request;

        if (address(orderHook) != address(0)) {
            orderHook.postPlaceOrder(orderId, extradata);
        }

        emit OrderPlaced(orderId, order, request);
    }

    function _createIncreasePositionOrder(
        IPool _pool,
        Side _side,
        address _indexToken,
        address _collateralToken,
        OrderType _orderType,
        bytes memory _data
    ) internal returns (uint256 orderId) {
        Order memory order;
        UpdatePositionRequest memory request;
        order.triggerAboveThreshold = _side == Side.SHORT;
        address purchaseToken;
        uint256 purchaseAmount;
        bytes memory extradata;
        (order.price, purchaseToken, purchaseAmount, request.sizeChange, request.collateral, extradata) = abi.decode(
            _data,
            (uint256, address, uint256, uint256, uint256, bytes)
        );

        require(purchaseAmount > 0, "OrderManager:invalidPurchaseAmount");
        require(purchaseToken != address(0), "OrderManager:invalidPurchaseToken");

        order.pool = _pool;
        order.owner = msg.sender;
        order.indexToken = _indexToken;
        order.collateralToken = _collateralToken;
        order.expiresAt = _orderType == OrderType.MARKET ? block.timestamp + MARKET_ORDER_TIMEOUT : 0;
        order.submissionBlock = block.number;
        order.executionFee = purchaseToken == UniERC20.ETH ? msg.value - purchaseAmount : msg.value;
        require(order.executionFee >= minExecutionFee, "OrderManager:executionFeeTooLow");
        request.updateType = UpdatePositionType.INCREASE;
        request.side = _side;
        orderId = nextOrderId;
        nextOrderId = orderId + 1;
        orders[orderId] = order;
        requests[orderId] = request;

        // swap
        if (purchaseToken != _collateralToken) {
            _poolSwap(_pool, purchaseToken, _collateralToken, purchaseAmount, request.collateral, address(this));
        } else if (purchaseToken != UniERC20.ETH) {
            IERC20(purchaseToken).safeTransferFrom(msg.sender, address(this), request.collateral);
        }

        if (address(orderHook) != address(0)) {
            orderHook.postPlaceOrder(orderId, extradata);
        }

        emit OrderPlaced(orderId, order, request);
    }

    function _poolSwap(
        IPool _pool,
        address _fromToken,
        address _toToken,
        uint256 _amountIn,
        uint256 _minAmountOut,
        address receiver
    ) internal {
        if (_fromToken == UniERC20.ETH) {
            UniERC20.safeTransferETH(address(_pool), _amountIn);
        } else {
            IERC20(_fromToken).safeTransferFrom(msg.sender, address(_pool), _amountIn);
        }
        _pool.swap(_fromToken, _toToken, _minAmountOut, receiver);
    }

    function _expiresOrder(uint256 _orderId, Order memory _order) internal {
        UpdatePositionRequest memory request = requests[_orderId];
        delete orders[_orderId];
        delete requests[_orderId];
        emit OrderExpired(_orderId);

        UniERC20.safeTransferETH(_order.owner, _order.executionFee);
        if (request.updateType == UpdatePositionType.INCREASE) {
            IERC20(_order.collateralToken).transferTo(_order.owner, request.collateral);
        }
    }

    // ============ Administrative =============

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "OrderManager:invalidOracleAddress");
        oracle = IOracle(_oracle);
        emit OracleChanged(_oracle);
    }

    function addPool(address _pool) external onlyOwner {
        require(!isPool[_pool], "OrderManager:poolAlreadyAdded");
        require(_pool != address(0), "OrderManager:invalidPoolAddress");
        isPool[_pool] = true;
        allPools.push(_pool);
        emit PoolAdded(_pool);
    }

    function removePool(address _pool) external onlyOwner {
        require(isPool[_pool], "OrderManager:poolNotAdded");
        isPool[_pool] = false;

        for (uint256 i = 0; i < allPools.length; i++) {
            if (allPools[i] == _pool) {
                allPools[i] = allPools[allPools.length - 1];
                break;
            }
        }
        allPools.pop();
        emit PoolRemoved(_pool);
    }

    function setMinExecutionFee(uint256 _fee) external onlyOwner {
        require(_fee > 0, "OrderManager:invalidFeeValue");
        minExecutionFee = _fee;
        emit MinExecutionFeeSet(_fee);
    }

    function setOrderHook(address _hook) external onlyOwner {
        orderHook = IOrderHook(_hook);
        emit OrderHookSet(_hook);
    }

    // ========== EVENTS =========

    event OrderPlaced(uint256 indexed key, Order order, UpdatePositionRequest request);
    event OrderCancelled(uint256 indexed key);
    event OrderExecuted(uint256 indexed key, Order order, UpdatePositionRequest request, uint256 fillPrice);
    event OrderExpired(uint256 indexed key);
    event OracleChanged(address);
    event SwapOrderPlaced(uint256 indexed key);
    event SwapOrderCancelled(uint256 indexed key);
    event SwapOrderExecuted(uint256 indexed key, uint256 amountIn, uint256 amountOut);
    event Swap(
        address indexed account,
        address indexed tokenIn,
        address indexed tokenOut,
        address pool,
        uint256 amountIn,
        uint256 amountOut
    );
    event PoolAdded(address);
    event PoolRemoved(address);
    event MinExecutionFeeSet(uint256 fee);
    event OrderHookSet(address hook);
}
