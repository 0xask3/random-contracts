// SPDX-License-Identifier: MIT

pragma solidity ^0.8.16;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract VestedICO is Context, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    struct Plan {
        uint16 discountPerc; //with 2 additional zeros
        uint16 apy; //with 2 additional zeros
        uint32 startDate; //timestamp
        uint32 endDate; //timestamp
        uint32 lockPeriod; //In seconds
        uint16 totalInvestors;
        uint256 minPerUser; // In eth
        uint256 maxPerUser; // In eth
        uint256 hardCap; //In eth
        uint256 ethRaised;
        uint256 tokensSold;
    }

    struct User {
        bool isClaimed;
        uint256 purchaseTime;
        uint256 ethSpent;
        uint256 tokensReceived;
    }

    mapping(uint8 => Plan) public plans;
    mapping(uint8 => mapping(address => User)) public users;

    IERC20 public _token;
    IUniswapV2Router02 private _router;

    event TokensPurchased(
        uint8 planId,
        address indexed purchaser,
        uint256 value,
        uint256 amount
    );
    event TokensClaimed(uint8 planId, uint256 amount, uint256 timestamp);

    constructor(IERC20 token, IUniswapV2Router02 router) {
        require(
            address(token) != address(0),
            "VestedICO: token is the zero address"
        );
        _token = token;
        _router = router;
    }

    function setPlan(
        uint8 _planId,
        uint16 apy, //with 2 additional zeros
        uint16 discountPerc, //with 2 additional zeros
        uint32 startDate, //timestamp
        uint32 endDate, //timestamp
        uint32 lockPeriod, //In seconds
        uint256 minPerUser, // In eth
        uint256 maxPerUser, // In eth
        uint256 hardCap //In eth
    ) external onlyOwner {
        Plan storage plan = plans[_planId];

        plan.apy = apy;
        plan.discountPerc = discountPerc;
        plan.startDate = startDate;
        plan.endDate = endDate;
        plan.lockPeriod = lockPeriod;
        plan.minPerUser = minPerUser;
        plan.maxPerUser = maxPerUser;
        plan.hardCap = hardCap;
    }

    function buyTokens(uint8 planId) external payable nonReentrant {
        uint256 ethAmount = msg.value;
        _preValidatePurchase(planId, msg.sender, ethAmount);

        Plan storage plan = plans[planId];

        uint256 tokens = _getTokenAmount(planId, ethAmount);

        plan.totalInvestors++;
        plan.ethRaised += msg.value;
        plan.tokensSold += tokens;

        _processPurchase(planId, msg.value, tokens);
        emit TokensPurchased(planId, msg.sender, msg.value, tokens);
    }

    function _preValidatePurchase(
        uint8 planId,
        address user,
        uint256 ethAmount
    ) internal view {
        Plan memory plan = plans[planId];

        require(
            ethAmount >= plan.minPerUser && ethAmount <= plan.maxPerUser,
            "Amount exceeds limit"
        );
        require(
            plan.ethRaised + ethAmount <= plan.hardCap,
            "Exceeding hardcap"
        );
        require(
            block.timestamp >= plan.startDate &&
                block.timestamp <= plan.endDate,
            "ICO not active"
        );
        require(
            users[planId][user].purchaseTime == 0,
            "User already participated"
        );
    }

    function _processPurchase(
        uint8 planId,
        uint256 ethAmount,
        uint256 tokenAmount
    ) internal {
        User storage user = users[planId][msg.sender];

        user.ethSpent = ethAmount;
        user.purchaseTime = block.timestamp;
        user.tokensReceived = tokenAmount;
    }

    function _getTokenAmount(uint8 planId, uint256 ethAmount)
        internal
        view
        returns (uint256)
    {
        address[] memory path = new address[](2);
        path[0] = _router.WETH();
        path[1] = address(_token);

        uint256 tokens = (_router.getAmountsOut(ethAmount, path))[
            path.length - 1
        ]; //Actual token amount based on price
        ethAmount =
            ethAmount -
            ((ethAmount * plans[planId].discountPerc) / 10000); //Apply discount
        uint256 tokensReceived = tokens / ethAmount; //Calculate new amount of tokens
        return tokensReceived;
    }

    function claimToken(uint8 planId) external {
        User storage user = users[planId][msg.sender];
        require(!user.isClaimed, "Already claimed");
        require(
            block.timestamp >= plans[planId].lockPeriod + user.purchaseTime,
            "Still locked"
        );

        user.isClaimed = true;
        uint256 tokensToSend = user.tokensReceived +
            ((user.tokensReceived * plans[planId].apy) / 10000);

        _token.safeTransfer(msg.sender, tokensToSend);
        emit TokensClaimed(planId, tokensToSend, block.timestamp);
    }

    function withdrawAllToken(address token, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (token == address(0)) {
            payable(owner()).transfer(amount);
        } else {
            IERC20 erc20token = IERC20(_token);
            erc20token.transfer(owner(), amount);
        }
    }
}
