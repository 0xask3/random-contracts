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
        uint256 tokensSold;
    }

    struct Token {
        bool isSupported;
        uint256 minPerUser;
        uint256 maxPerUser;
        uint256 hardCap;
        uint256 totalRaised;
    }

    struct User {
        bool isClaimed;
        uint256 purchaseTime;
        mapping(address => uint256) tokenSpent;
        uint256 tokensReceived;
    }

    mapping(uint8 => Plan) public plans;
    mapping(uint8 => mapping(address => User)) public users;
    mapping(address => Token) public tokens;

    IERC20 public _token;
    IUniswapV2Router02 private _router;

    event TokensPurchased(
        uint8 planId,
        address token,
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

    function setToken(
        address tkn,
        bool isSupported,
        uint256 minPerUser, // with decimals
        uint256 maxPerUser, // with decimals
        uint256 hardCap // with decimals
    ) external onlyOwner {
        Token storage token = tokens[tkn];

        token.isSupported = isSupported;
        token.minPerUser = minPerUser;
        token.maxPerUser = maxPerUser;
        token.hardCap = hardCap;
    }

    function setPlan(
        uint8 _planId,
        uint16 apy, //with 2 additional zeros
        uint16 discountPerc, //with 2 additional zeros
        uint32 startDate, //timestamp
        uint32 endDate, //timestamp
        uint32 lockPeriod //In seconds
    ) external onlyOwner {
        Plan storage plan = plans[_planId];

        plan.apy = apy;
        plan.discountPerc = discountPerc;
        plan.startDate = startDate;
        plan.endDate = endDate;
        plan.lockPeriod = lockPeriod;
    }

    function buyTokens(
        uint8 planId,
        address token,
        uint256 amount
    ) external payable nonReentrant {
        uint256 ethAmount;
        if (token == address(0)) {
            ethAmount = msg.value;
        } else {
            IERC20(token).transferFrom(msg.sender, address(this), amount);
            ethAmount = amount;
        }

        _preValidatePurchase(planId, msg.sender, token, ethAmount);

        Plan storage plan = plans[planId];

        uint256 tokensGot = _getTokenAmount(planId, token, ethAmount);

        plan.totalInvestors++;
        plan.tokensSold += tokensGot;
        tokens[token].totalRaised += amount;

        _processPurchase(planId, token, ethAmount, tokensGot);
        emit TokensPurchased(planId, token, msg.sender, ethAmount, tokensGot);
    }

    function _preValidatePurchase(
        uint8 planId,
        address user,
        address tkn,
        uint256 ethAmount
    ) internal view {
        Plan memory plan = plans[planId];
        Token memory token = tokens[tkn];

        require(
            ethAmount >= token.minPerUser && ethAmount <= token.maxPerUser,
            "Amount exceeds limit"
        );
        require(
            token.totalRaised + ethAmount <= token.hardCap,
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
        address token,
        uint256 amount,
        uint256 tokenAmount
    ) internal {
        User storage user = users[planId][msg.sender];

        user.tokenSpent[token] = amount;
        user.purchaseTime = block.timestamp;
        user.tokensReceived = tokenAmount;
    }

    function _getTokenAmount(
        uint8 planId,
        address token,
        uint256 amount
    ) internal view returns (uint256) {
        address[] memory path;
        if (token == address(0)) {
            path = new address[](2);
            path[0] = _router.WETH();
            path[1] = address(_token);
        } else {
            path = new address[](3);
            path[0] = _router.WETH();
            path[1] = address(_token);
        }

        uint256 tokensOut = (_router.getAmountsOut(amount, path))[
            path.length - 1
        ]; //Actual token amount based on price
        amount = amount - ((amount * plans[planId].discountPerc) / 10000); //Apply discount
        uint256 tokensReceived = tokensOut / amount; //Calculate new amount of tokens
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
