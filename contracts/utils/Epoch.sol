pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/Math.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';

import '../owner/Operator.sol';

//时代，理解为是一种循环的概念，每个循环执行特定操作。
contract Epoch is Operator {
    using SafeMath for uint256;

    uint256 private period;  //时间间隔
    uint256 private startTime;  //开始时间
    uint256 private lastExecutedAt; //上次执行的时间

    /* ========== CONSTRUCTOR ========== */

    constructor(
        uint256 _period,
        uint256 _startTime,
        uint256 _startEpoch
    ) public {
        require(_startTime > block.timestamp, 'Epoch: invalid start time');
        period = _period;
        startTime = _startTime;
        lastExecutedAt = startTime.add(_startEpoch.mul(period));
    }

    /* ========== Modifier ========== */

    modifier checkStartTime {
        require(now >= startTime, 'Epoch: not started yet');

        _;
    }

    modifier checkEpoch {
        require(now > startTime, 'Epoch: not started yet');
        require(callable(), 'Epoch: not allowed');

        _;

        lastExecutedAt = block.timestamp;
    }

    /* ========== VIEW FUNCTIONS ========== */

    //是否可以调用。当前时代大于nextEpoch时，说明可调用。
    function callable() public view returns (bool) {
        return getCurrentEpoch() >= getNextEpoch();
    }

    // epoch 获取上一个时代数。用上一次执行的时间减去开始时间，除以间隔
    function getLastEpoch() public view returns (uint256) {
        return lastExecutedAt.sub(startTime).div(period);
    }

    //获取当前时代数。由于可能还未到开始是时间，所以取startTime和当前区块时间的max计算。
    function getCurrentEpoch() public view returns (uint256) {
        return Math.max(startTime, block.timestamp).sub(startTime).div(period);
    }

    //获取下一个时代数。如果尚未执行，取0
    function getNextEpoch() public view returns (uint256) {
        if (startTime == lastExecutedAt) {
            return getLastEpoch();
        }
        return getLastEpoch().add(1);
    }

    //
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(getNextEpoch().mul(period));
    }

    // params
    function getPeriod() public view returns (uint256) {
        return period;
    }

    function getStartTime() public view returns (uint256) {
        return startTime;
    }

    /* ========== GOVERNANCE ========== */

    //设置间隔，只有治理者才能设置。感觉这样设置，会导致上面的getLastEpoch计算有问题
    function setPeriod(uint256 _period) external onlyOperator {
        period = _period;
    }
}
