pragma solidity ^0.6.0;

import '../distribution/BACDAIPool.sol';
import '../distribution/BACSUSDPool.sol';
import '../distribution/BACUSDCPool.sol';
import '../distribution/BACUSDTPool.sol';
import '../distribution/BACyCRVPool.sol';
import '../interfaces/IDistributor.sol';

//初始化cash分配器
contract InitialCashDistributor is IDistributor {
    using SafeMath for uint256;

    event Distributed(address pool, uint256 cashAmount);

    //只会执行一次
    bool public once = true;

    IERC20 public cash;
    IRewardDistributionRecipient[] public pools;
    uint256 public totalInitialBalance;

    constructor(
        IERC20 _cash,
        IRewardDistributionRecipient[] memory _pools,
        uint256 _totalInitialBalance
    ) public {
        require(_pools.length != 0, 'a list of BAC pools are required');

        cash = _cash;
        pools = _pools;
        totalInitialBalance = _totalInitialBalance;
    }

    //将cash平均分配到所有cash池子里，触发计算奖励
    function distribute() public override {
        require(
            once,
            'InitialCashDistributor: you cannot run this function twice'
        );

        for (uint256 i = 0; i < pools.length; i++) {
            uint256 amount = totalInitialBalance.div(pools.length);

            cash.transfer(address(pools[i]), amount);
            pools[i].notifyRewardAmount(amount);

            emit Distributed(address(pools[i]), amount);
        }

        once = false;
    }
}
