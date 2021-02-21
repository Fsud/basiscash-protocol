pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/Math.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import {ICurve} from './curve/Curve.sol';
import {IOracle} from './interfaces/IOracle.sol';
import {IBoardroom} from './interfaces/IBoardroom.sol';
import {IBasisAsset} from './interfaces/IBasisAsset.sol';
import {ISimpleERCFund} from './interfaces/ISimpleERCFund.sol';
import {Babylonian} from './lib/Babylonian.sol';
import {FixedPoint} from './lib/FixedPoint.sol';
import {Safe112} from './lib/Safe112.sol';
import {Operator} from './owner/Operator.sol';
import {Epoch} from './utils/Epoch.sol';
import {ContractGuard} from './utils/ContractGuard.sol';

/**
 * 金库合约，调整基础现金资产供应的货币政策逻辑
 * @title Basis Cash Treasury contract
 * @notice Monetary policy logic to adjust supplies of basis cash assets
 * @author Summer Smith & Rick Sanchez
 */
contract Treasury is ContractGuard, Epoch {
    using FixedPoint for *;
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using Safe112 for uint112;

    /* ========== STATE VARIABLES ========== */

    // ========== FLAGS
    bool public migrated = false;
    bool public initialized = false;

    // ========== CORE
    address public fund;
    address public cash;
    address public bond;
    address public share;
    address public curve;
    address public boardroom;

    address public bondOracle;
    address public seigniorageOracle;

    // ========== PARAMS
    uint256 public cashPriceOne;

    uint256 public lastBondOracleEpoch = 0;
    uint256 public bondCap = 0;
    uint256 public accumulatedSeigniorage = 0;
    uint256 public fundAllocationRate = 2; // %

    /* ========== CONSTRUCTOR ========== */
    /** 构造函数，分别传入三种代币的地址，bond预言机，cash预言机，board合约地址，开发者基金地址，开始时间 */
    constructor(
        address _cash,  
        address _bond,
        address _share,
        address _bondOracle,
        address _seigniorageOracle,
        address _boardroom,
        address _fund,
        address _curve,
        uint256 _startTime
    ) public Epoch(1 days, _startTime, 0) {
        cash = _cash;
        bond = _bond;
        share = _share;
        curve = _curve;
        bondOracle = _bondOracle;
        seigniorageOracle = _seigniorageOracle;

        boardroom = _boardroom;
        fund = _fund;

        cashPriceOne = 10**18;
    }

    /* =================== Modifier =================== */

    //需要尚未迁移
    modifier checkMigration {
        require(!migrated, 'Treasury: migrated');

        _;
    }

    //操作者需要是四个合约的操作者
    modifier checkOperator {
        require(
            IBasisAsset(cash).operator() == address(this) &&
                IBasisAsset(bond).operator() == address(this) &&
                IBasisAsset(share).operator() == address(this) &&
                Operator(boardroom).operator() == address(this),
            'Treasury: need more permission'
        );

        _;
    }

    //更新cash价格
    modifier updatePrice {
        _;

        _updateCashPrice();
    }

    /* ========== VIEW FUNCTIONS ========== */

    // 财政预算 铸币税
    function getReserve() public view returns (uint256) {
        return accumulatedSeigniorage;
    }

    function circulatingSupply() public view returns (uint256) {
        return IERC20(cash).totalSupply().sub(accumulatedSeigniorage);
    }

    function getCeilingPrice() public view returns (uint256) {
        return ICurve(curve).calcCeiling(circulatingSupply());
    }

    // oracle
    function getBondOraclePrice() public view returns (uint256) {
        return _getCashPrice(bondOracle);
    }

    function getSeigniorageOraclePrice() public view returns (uint256) {
        return _getCashPrice(seigniorageOracle);
    }

    //从预言机获取cash价格
    function _getCashPrice(address oracle) internal view returns (uint256) {
        try IOracle(oracle).consult(cash, 1e18) returns (uint256 price) {
            return price;
        } catch {
            revert('Treasury: failed to consult cash price from the oracle');
        }
    }

    /* ========== GOVERNANCE ========== */

    // MIGRATION
    function initialize() public checkOperator {
        require(!initialized, 'Treasury: initialized');

        // set accumulatedSeigniorage to it's balance
        accumulatedSeigniorage = IERC20(cash).balanceOf(address(this));

        initialized = true;
        emit Initialized(msg.sender, block.number);
    }

    //进行三个代币合约的迁移，将拥有者和操作者从开发者迁移到target合约——timelock
    function migrate(address target) public onlyOperator checkOperator {
        require(!migrated, 'Treasury: migrated');

        // cash
        Operator(cash).transferOperator(target);
        Operator(cash).transferOwnership(target);
        IERC20(cash).transfer(target, IERC20(cash).balanceOf(address(this)));

        // bond
        Operator(bond).transferOperator(target);
        Operator(bond).transferOwnership(target);
        IERC20(bond).transfer(target, IERC20(bond).balanceOf(address(this)));

        // share
        Operator(share).transferOperator(target);
        Operator(share).transferOwnership(target);
        IERC20(share).transfer(target, IERC20(share).balanceOf(address(this)));

        migrated = true;
        emit Migration(target);
    }

    // FUND开发者基金地址变更
    function setFund(address newFund) public onlyOperator {
        address oldFund = fund;
        fund = newFund;
        emit ContributionPoolChanged(msg.sender, oldFund, newFund);
    }

    // 设置fund抽成率
    function setFundAllocationRate(uint256 newRate) public onlyOperator {
        uint256 oldRate = fundAllocationRate;
        fundAllocationRate = newRate;
        emit ContributionPoolRateChanged(msg.sender, oldRate, newRate);
    }

    // ORACLE
    function setBondOracle(address newOracle) public onlyOperator {
        address oldOracle = bondOracle;
        bondOracle = newOracle;
        emit BondOracleChanged(msg.sender, oldOracle, newOracle);
    }

    function setSeigniorageOracle(address newOracle) public onlyOperator {
        address oldOracle = seigniorageOracle;
        seigniorageOracle = newOracle;
        emit SeigniorageOracleChanged(msg.sender, oldOracle, newOracle);
    }

    // TWEAK
    function setCeilingCurve(address newCurve) public onlyOperator {
        address oldCurve = newCurve;
        curve = newCurve;
        emit CeilingCurveChanged(msg.sender, oldCurve, newCurve);
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateConversionLimit(uint256 cashPrice) internal {
        uint256 currentEpoch = Epoch(bondOracle).getLastEpoch(); // lastest update time
        if (lastBondOracleEpoch != currentEpoch) {
            uint256 percentage = cashPriceOne.sub(cashPrice);
            uint256 bondSupply = IERC20(bond).totalSupply();

            bondCap = circulatingSupply().mul(percentage).div(1e18);
            bondCap = bondCap.sub(Math.min(bondCap, bondSupply));

            lastBondOracleEpoch = currentEpoch;
        }
    }

    //更新两个oracle的价格
    function _updateCashPrice() internal {
        if (Epoch(bondOracle).callable()) {
            try IOracle(bondOracle).update() {} catch {}
        }
        if (Epoch(seigniorageOracle).callable()) {
            try IOracle(seigniorageOracle).update() {} catch {}
        }
    }

    //买债券
    function buyBonds(uint256 amount, uint256 targetPrice)
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkOperator
        updatePrice
    {
        //校验购买数量、当前cash价格
        require(amount > 0, 'Treasury: cannot purchase bonds with zero amount');

        uint256 cashPrice = _getCashPrice(bondOracle);
        require(cashPrice <= targetPrice, 'Treasury: cash price moved');
        require(
            cashPrice < cashPriceOne, // price < $1
            'Treasury: cashPrice not eligible for bond purchase'
        );
        //更新债券限额
        _updateConversionLimit(cashPrice);

        //计算债券限额
        amount = Math.min(amount, bondCap.mul(cashPrice).div(1e18));
        require(amount > 0, 'Treasury: amount exceeds bond cap');

        //燃烧bac
        IBasisAsset(cash).burnFrom(msg.sender, amount);
        //铸造bab，使用burn的bac数量 / bac 价格
        IBasisAsset(bond).mint(msg.sender, amount.mul(1e18).div(cashPrice));

        emit BoughtBonds(msg.sender, amount);
    }

    //赎回债券——使用债券bab换回bac
    function redeemBonds(uint256 amount)
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkOperator
        updatePrice
    {
        //赎回cash数量必须大于0
        require(amount > 0, 'Treasury: cannot redeem bonds with zero amount');

        //获取cash现在的价格
        uint256 cashPrice = _getCashPrice(bondOracle);
        require(
            //cash现在的价格必须大于1.05. 老版本代码是写死的
            cashPrice > getCeilingPrice(), // price > $1.05
            'Treasury: cashPrice not eligible for bond purchase'
        );
        require(
            // 当前合约中的剩余数量的cash必须
            IERC20(cash).balanceOf(address(this)) >= amount,
            'Treasury: treasury has no more budget'
        );

        //当前国库的总cash数量减少amount。不能小于0
        accumulatedSeigniorage = accumulatedSeigniorage.sub(
            Math.min(accumulatedSeigniorage, amount)
        );

        //燃烧掉sender地址的bound
        IBasisAsset(bond).burnFrom(msg.sender, amount);

        //将cash发送给sender
        IERC20(cash).safeTransfer(msg.sender, amount);

        emit RedeemedBonds(msg.sender, amount);
    }

    //
    function allocateSeigniorage()
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkEpoch
        checkOperator
    {
        _updateCashPrice();

        //获取cash价格
        uint256 cashPrice = _getCashPrice(seigniorageOracle);
        //cash价格小于1.05，不进行操作
        if (cashPrice <= getCeilingPrice()) {
            return; // just advance epoch instead revert
        }

        // 计算增发百分比，进行增发
        uint256 percentage = cashPrice.sub(cashPriceOne);
        uint256 seigniorage = circulatingSupply().mul(percentage).div(1e18);
        //进行mint增发
        IBasisAsset(cash).mint(address(this), seigniorage);

        // ======================== BIP-3
        // 计算开发者基金抽取的增发cash的数量
        uint256 fundReserve = seigniorage.mul(fundAllocationRate).div(100);
        if (fundReserve > 0) {
            //把当前合约中的一定数量的fund发送给fund
            IERC20(cash).safeApprove(fund, fundReserve);
            ISimpleERCFund(fund).deposit(
                cash,
                fundReserve,
                'Treasury: Seigniorage Allocation'
            );
            emit ContributionPoolFunded(now, fundReserve);
        }

        //增发数量减掉fund
        seigniorage = seigniorage.sub(fundReserve);

        // ======================== BIP-4
        // 对比bund缺口和当前增发数量。bund缺口更大，则国库预留全部增发的cash，后续给bund使用；bund缺口小，则只预留bund缺口的
        uint256 treasuryReserve =
            Math.min(
                seigniorage,
                IERC20(bond).totalSupply().sub(accumulatedSeigniorage)
            );
        // 如果国库需要预留
        if (treasuryReserve > 0) {
            // 如果预留的不足以弥补bund缺口，则只预留80%
            if (treasuryReserve == seigniorage) {
                treasuryReserve = treasuryReserve.mul(80).div(100);
            }
            // 计算累计增发数量
            accumulatedSeigniorage = accumulatedSeigniorage.add(
                treasuryReserve
            );
            emit TreasuryFunded(now, treasuryReserve);
        }

        // boardroom
        // 增发数量减掉国库数量，是分配给董事会的数量，进行分配。
        uint256 boardroomReserve = seigniorage.sub(treasuryReserve);
        if (boardroomReserve > 0) {
            IERC20(cash).safeApprove(boardroom, boardroomReserve);
            IBoardroom(boardroom).allocateSeigniorage(boardroomReserve);
            emit BoardroomFunded(now, boardroomReserve);
        }
    }

    /* ========== EVENTS ========== */

    // GOV
    event Initialized(address indexed executor, uint256 at);
    event Migration(address indexed target);
    event ContributionPoolChanged(
        address indexed operator,
        address oldFund,
        address newFund
    );
    event ContributionPoolRateChanged(
        address indexed operator,
        uint256 oldRate,
        uint256 newRate
    );
    event BondOracleChanged(
        address indexed operator,
        address oldOracle,
        address newOracle
    );
    event SeigniorageOracleChanged(
        address indexed operator,
        address oldOracle,
        address newOracle
    );
    event CeilingCurveChanged(
        address indexed operator,
        address oldCurve,
        address newCurve
    );

    // CORE
    event RedeemedBonds(address indexed from, uint256 amount);
    event BoughtBonds(address indexed from, uint256 amount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event ContributionPoolFunded(uint256 timestamp, uint256 seigniorage);
}
