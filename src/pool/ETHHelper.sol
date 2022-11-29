pragma solidity 0.8.15;

import {IPool} from "../interfaces/IPool.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {ILPToken} from "../interfaces/ILPToken.sol";
import {SafeERC20, IERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

contract ETHHelper {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;

    IPool public pool;
    IWETH public weth;

    constructor(address _pool, address _weth) {
        require(_pool != address(0), "ETHHelper:zeroAddress");
        require(_weth != address(0), "ETHHelper:zeroAddress");

        pool = IPool(_pool);
        weth = IWETH(_weth);
    }

    function addLiquidity(address _tranche, uint256 _minLpAmount, address _to) external payable {
        uint256 amountIn = msg.value;
        weth.deposit{value: amountIn}();
        weth.safeIncreaseAllowance(address(pool), amountIn);
        pool.addLiquidity(_tranche, address(weth), amountIn, _minLpAmount, _to);
    }

    function removeLiquidity(address _tranche, uint256 _lpAmount, uint256 _minOut, address payable _to)
        external
        payable
    {
        IERC20 lpToken = IERC20(_tranche);
        lpToken.safeTransferFrom(msg.sender, address(this), _lpAmount);
        lpToken.safeIncreaseAllowance(address(pool), _lpAmount);
        uint256 balanceBefore = weth.balanceOf(address(this));
        pool.removeLiquidity(_tranche, address(weth), _lpAmount, _minOut, address(this));
        uint256 received = weth.balanceOf(address(this)) - balanceBefore;
        weth.withdraw(received);
        safeTransferETH(_to, received);
    }

    function safeTransferETH(address to, uint256 amount) internal {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = to.call{value: amount}(new bytes(0));
        require(success, "TransferHelper: ETH_TRANSFER_FAILED");
    }

    receive() external payable {}
}
