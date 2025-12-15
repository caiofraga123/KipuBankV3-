// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// Uniswap V4 Interfaces
interface IUniversalRouter {
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable;
}

interface IPermit2 {
    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external;
    
    function allowance(
        address user,
        address token,
        address spender
    ) external view returns (uint160 amount, uint48 expiration, uint48 nonce);
}

interface IPoolManager {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }
}

/**
 * @title KipuBankV3
 * @author KipuBank Team
 * @notice Advanced multi-asset vault with automatic USDC conversion via Uniswap V4
 * @dev Extends V2 functionality with arbitrary token deposits that auto-swap to USDC
 * 
 * Key Features:
 * - Accept any Uniswap V4 tradeable token
 * - Automatic conversion to USDC using UniversalRouter
 * - Maintains all V2 functionality (ETH, direct USDC, price feeds)
 * - Enforces bank cap on final USDC amounts
 */
contract KipuBankV3 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Represents a supported asset in the bank
    struct Asset {
        address tokenAddress;      // Address of the token (address(0) for native ETH)
        uint8 decimals;           // Number of decimals
        address priceFeed;        // Chainlink price feed address (token/USD)
        bool isActive;            // Whether deposits/withdrawals are enabled
        uint256 totalDeposited;   // Total amount deposited in native token decimals
        bool requiresSwap;        // If true, token must be swapped to USDC
    }

    /// @notice Transaction history record
    struct Transaction {
        address token;
        uint256 amount;
        uint256 timestamp;
        bool isDeposit;
        uint256 usdcReceived;     // USDC amount after swap (if applicable)
    }

    /// @notice Parameters for Uniswap V4 swap
    struct SwapParams {
        address tokenIn;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint24 fee;               // Pool fee tier (500 = 0.05%, 3000 = 0.3%, 10000 = 1%)
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Role identifiers
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /// @notice Maximum withdrawal amount per transaction in USD (6 decimals)
    uint256 public immutable WITHDRAWAL_LIMIT_USD;

    /// @notice Maximum total deposits in USD (6 decimals)
    uint256 public constant BANK_CAP_USD = 1_000_000 * 1e6; // $1M

    /// @notice Standard decimal places for internal accounting
    uint8 public constant ACCOUNTING_DECIMALS = 6;

    /// @notice Native ETH identifier
    address public constant NATIVE_ETH = address(0);

    /// @notice USDC token address (Sepolia)
    address public immutable USDC;

    /// @notice Uniswap V4 UniversalRouter
    IUniversalRouter public immutable universalRouter;

    /// @notice Permit2 contract for token approvals
    IPermit2 public immutable permit2;

    /// @notice Current total value locked in USD (6 decimals)
    uint256 public totalValueLockedUSD;

    /// @notice Transaction counters
    uint256 public depositCount;
    uint256 public withdrawalCount;

    /// @notice Emergency pause state
    bool public paused;

    /// @notice Slippage tolerance (in basis points, 50 = 0.5%)
    uint256 public slippageTolerance = 50;

    /// @notice Mapping of token address => Asset metadata
    mapping(address => Asset) public supportedAssets;

    /// @notice Nested mapping: user => token => balance (in 6 decimals)
    mapping(address => mapping(address => uint256)) private userVaults;

    /// @notice User transaction history
    mapping(address => Transaction[]) private userTransactions;

    /// @notice List of supported token addresses
    address[] public assetList;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 valueUSD,
        uint256 newBalance
    );

    event Withdrawal(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 valueUSD,
        uint256 remainingBalance
    );

    event TokenSwapped(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    event AssetAdded(
        address indexed token,
        uint8 decimals,
        address priceFeed,
        bool requiresSwap
    );

    event AssetStatusUpdated(address indexed token, bool isActive);
    event EmergencyPause(address indexed triggeredBy, uint256 timestamp);
    event Unpaused(address indexed triggeredBy, uint256 timestamp);
    event SlippageToleranceUpdated(uint256 oldValue, uint256 newValue);

    /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/

    error KipuBankV3__DepositAmountMustBeGreaterThanZero();
    error KipuBankV3__BankCapacityExceeded(uint256 attempted, uint256 available);
    error KipuBankV3__WithdrawalAmountMustBeGreaterThanZero();
    error KipuBankV3__WithdrawalExceedsLimit(uint256 attempted, uint256 limit);
    error KipuBankV3__InsufficientBalance(uint256 requested, uint256 available);
    error KipuBankV3__TransferFailed();
    error KipuBankV3__AssetNotSupported(address token);
    error KipuBankV3__AssetNotActive(address token);
    error KipuBankV3__AssetAlreadyExists(address token);
    error KipuBankV3__InvalidPriceFeed(address priceFeed);
    error KipuBankV3__PriceStale();
    error KipuBankV3__InvalidPrice();
    error KipuBankV3__ContractPaused();
    error KipuBankV3__NotPaused();
    error KipuBankV3__SwapFailed(string reason);
    error KipuBankV3__InsufficientSwapOutput(uint256 received, uint256 minimum);
    error KipuBankV3__InvalidSlippage();

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes KipuBankV3
     * @param _withdrawalLimitUSD Maximum withdrawal per transaction in USD (6 decimals)
     * @param _usdc USDC token address
     * @param _universalRouter Uniswap V4 UniversalRouter address
     * @param _permit2 Permit2 contract address
     */
    constructor(
        uint256 _withdrawalLimitUSD,
        address _usdc,
        address _universalRouter,
        address _permit2
    ) {
        require(_usdc != address(0), "Invalid USDC address");
        require(_universalRouter != address(0), "Invalid router address");
        require(_permit2 != address(0), "Invalid Permit2 address");

        WITHDRAWAL_LIMIT_USD = _withdrawalLimitUSD;
        USDC = _usdc;
        universalRouter = IUniversalRouter(_universalRouter);
        permit2 = IPermit2(_permit2);

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier validAmount(uint256 amount) {
        if (amount == 0) {
            revert KipuBankV3__DepositAmountMustBeGreaterThanZero();
        }
        _;
    }

    modifier onlySupportedAsset(address token) {
        if (!supportedAssets[token].isActive) {
            if (supportedAssets[token].tokenAddress == address(0)) {
                revert KipuBankV3__AssetNotSupported(token);
            }
            revert KipuBankV3__AssetNotActive(token);
        }
        _;
    }

    modifier whenNotPaused() {
        if (paused) {
            revert KipuBankV3__ContractPaused();
        }
        _;
    }

    modifier whenPaused() {
        if (!paused) {
            revert KipuBankV3__NotPaused();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds a new supported asset
     * @param token Token address (address(0) for ETH)
     * @param decimals Token decimals
     * @param priceFeed Chainlink price feed
     * @param requiresSwap Whether token needs to be swapped to USDC
     */
    function addAsset(
        address token,
        uint8 decimals,
        address priceFeed,
        bool requiresSwap
    ) external onlyRole(ADMIN_ROLE) {
        if (supportedAssets[token].tokenAddress != address(0)) {
            revert KipuBankV3__AssetAlreadyExists(token);
        }
        if (priceFeed == address(0)) {
            revert KipuBankV3__InvalidPriceFeed(priceFeed);
        }

        _validatePriceFeed(priceFeed);

        supportedAssets[token] = Asset({
            tokenAddress: token,
            decimals: decimals,
            priceFeed: priceFeed,
            isActive: true,
            totalDeposited: 0,
            requiresSwap: requiresSwap
        });

        assetList.push(token);

        emit AssetAdded(token, decimals, priceFeed, requiresSwap);
    }

    function setAssetStatus(address token, bool isActive) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        if (supportedAssets[token].tokenAddress == address(0)) {
            revert KipuBankV3__AssetNotSupported(token);
        }
        supportedAssets[token].isActive = isActive;
        emit AssetStatusUpdated(token, isActive);
    }

    function setSlippageTolerance(uint256 _slippage) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        if (_slippage > 1000) { // Max 10%
            revert KipuBankV3__InvalidSlippage();
        }
        uint256 oldValue = slippageTolerance;
        slippageTolerance = _slippage;
        emit SlippageToleranceUpdated(oldValue, _slippage);
    }

    function emergencyPause() external onlyRole(EMERGENCY_ROLE) whenNotPaused {
        paused = true;
        emit EmergencyPause(msg.sender, block.timestamp);
    }

    function unpause() external onlyRole(ADMIN_ROLE) whenPaused {
        paused = false;
        emit Unpaused(msg.sender, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits native ETH (converts to USDC if needed)
     */
    function depositETH()
        external
        payable
        validAmount(msg.value)
        onlySupportedAsset(NATIVE_ETH)
        whenNotPaused
        nonReentrant
    {
        Asset memory asset = supportedAssets[NATIVE_ETH];
        
        if (asset.requiresSwap) {
            // Swap ETH to USDC
            uint256 usdcReceived = _swapExactInputSingle(
                SwapParams({
                    tokenIn: NATIVE_ETH,
                    amountIn: msg.value,
                    amountOutMinimum: _calculateMinimumOutput(NATIVE_ETH, msg.value),
                    fee: 3000 // 0.3% pool
                })
            );
            _creditUser(msg.sender, USDC, usdcReceived, msg.value, NATIVE_ETH);
        } else {
            _deposit(NATIVE_ETH, msg.value);
        }
    }

    /**
     * @notice Deposits USDC directly (no swap needed)
     * @param amount Amount of USDC to deposit
     */
    function depositUSDC(uint256 amount)
        external
        validAmount(amount)
        whenNotPaused
        nonReentrant
    {
        require(supportedAssets[USDC].isActive, "USDC not supported");
        
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);
        _deposit(USDC, amount);
    }

    /**
     * @notice Deposits arbitrary token and converts to USDC via Uniswap V4
     * @param token Token address to deposit
     * @param amount Amount to deposit
     * @param fee Pool fee tier (500, 3000, or 10000)
     */
    function depositArbitraryToken(
        address token,
        uint256 amount,
        uint24 fee
    )
        external
        validAmount(amount)
        onlySupportedAsset(token)
        whenNotPaused
        nonReentrant
    {
        require(token != NATIVE_ETH, "Use depositETH for native ETH");
        require(token != USDC, "Use depositUSDC for USDC");

        Asset memory asset = supportedAssets[token];
        require(asset.requiresSwap, "Token does not require swap");

        // Transfer token from user
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Approve Permit2 if needed
        _ensurePermit2Approval(token, amount);

        // Swap to USDC
        uint256 usdcReceived = _swapExactInputSingle(
            SwapParams({
                tokenIn: token,
                amountIn: amount,
                amountOutMinimum: _calculateMinimumOutput(token, amount),
                fee: fee
            })
        );

        // Credit user with USDC
        _creditUser(msg.sender, USDC, usdcReceived, amount, token);
    }

    /**
     * @notice Withdraws ETH from vault
     * @param amount Amount to withdraw (in 6 decimals)
     */
    function withdrawETH(uint256 amount)
        external
        validAmount(amount)
        whenNotPaused
        nonReentrant
    {
        _withdraw(NATIVE_ETH, amount);
    }

    /**
     * @notice Withdraws USDC from vault
     * @param amount Amount to withdraw (in 6 decimals)
     */
    function withdrawUSDC(uint256 amount)
        external
        validAmount(amount)
        whenNotPaused
        nonReentrant
    {
        _withdraw(USDC, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getVaultBalance(address user, address token)
        external
        view
        returns (uint256)
    {
        return userVaults[user][token];
    }

    function getMyBalance(address token) external view returns (uint256) {
        return userVaults[msg.sender][token];
    }

    function getAllBalances(address user)
        external
        view
        returns (address[] memory tokens, uint256[] memory balances)
    {
        tokens = new address[](assetList.length);
        balances = new uint256[](assetList.length);

        for (uint256 i = 0; i < assetList.length; i++) {
            tokens[i] = assetList[i];
            balances[i] = userVaults[user][assetList[i]];
        }
    }

    function getTransactionHistory(address user)
        external
        view
        returns (Transaction[] memory)
    {
        return userTransactions[user];
    }

    function getTokenPriceUSD(address token)
        external
        view
        returns (uint256 price)
    {
        return _getLatestPrice(token);
    }

    function convertToUSD(address token, uint256 amount)
        external
        view
        returns (uint256)
    {
        return _convertToUSD(token, amount);
    }

    function getSupportedAssets() external view returns (address[] memory) {
        return assetList;
    }

    function getAvailableCapacity() external view returns (uint256) {
        if (totalValueLockedUSD >= BANK_CAP_USD) {
            return 0;
        }
        return BANK_CAP_USD - totalValueLockedUSD;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal deposit logic
     */
    function _deposit(address token, uint256 amount) private {
        uint256 valueUSD = _convertToUSD(token, amount);

        if (totalValueLockedUSD + valueUSD > BANK_CAP_USD) {
            revert KipuBankV3__BankCapacityExceeded(
                totalValueLockedUSD + valueUSD,
                BANK_CAP_USD
            );
        }

        uint256 normalizedAmount = _normalizeDecimals(
            amount,
            supportedAssets[token].decimals,
            ACCOUNTING_DECIMALS
        );

        userVaults[msg.sender][token] += normalizedAmount;
        supportedAssets[token].totalDeposited += amount;
        totalValueLockedUSD += valueUSD;
        depositCount++;

        userTransactions[msg.sender].push(
            Transaction({
                token: token,
                amount: normalizedAmount,
                timestamp: block.timestamp,
                isDeposit: true,
                usdcReceived: 0
            })
        );

        emit Deposit(
            msg.sender,
            token,
            amount,
            valueUSD,
            userVaults[msg.sender][token]
        );
    }

    /**
     * @notice Credits user after swap
     */
    function _creditUser(
        address user,
        address creditToken,
        uint256 creditAmount,
        uint256 originalAmount,
        address originalToken
    ) private {
        uint256 valueUSD = _convertToUSD(creditToken, creditAmount);

        if (totalValueLockedUSD + valueUSD > BANK_CAP_USD) {
            revert KipuBankV3__BankCapacityExceeded(
                totalValueLockedUSD + valueUSD,
                BANK_CAP_USD
            );
        }

        uint256 normalizedAmount = _normalizeDecimals(
            creditAmount,
            supportedAssets[creditToken].decimals,
            ACCOUNTING_DECIMALS
        );

        userVaults[user][creditToken] += normalizedAmount;
        supportedAssets[creditToken].totalDeposited += creditAmount;
        totalValueLockedUSD += valueUSD;
        depositCount++;

        userTransactions[user].push(
            Transaction({
                token: originalToken,
                amount: normalizedAmount,
                timestamp: block.timestamp,
                isDeposit: true,
                usdcReceived: creditAmount
            })
        );

        emit Deposit(
            user,
            creditToken,
            creditAmount,
            valueUSD,
            userVaults[user][creditToken]
        );
    }

    /**
     * @notice Internal withdrawal logic
     */
    function _withdraw(address token, uint256 amount) private {
        if (amount > userVaults[msg.sender][token]) {
            revert KipuBankV3__InsufficientBalance(
                amount,
                userVaults[msg.sender][token]
            );
        }

        uint256 nativeAmount = _normalizeDecimals(
            amount,
            ACCOUNTING_DECIMALS,
            supportedAssets[token].decimals
        );

        uint256 valueUSD = _convertToUSD(token, nativeAmount);

        if (valueUSD > WITHDRAWAL_LIMIT_USD) {
            revert KipuBankV3__WithdrawalExceedsLimit(
                valueUSD,
                WITHDRAWAL_LIMIT_USD
            );
        }

        userVaults[msg.sender][token] -= amount;
        supportedAssets[token].totalDeposited -= nativeAmount;
        totalValueLockedUSD -= valueUSD;
        withdrawalCount++;

        userTransactions[msg.sender].push(
            Transaction({
                token: token,
                amount: amount,
                timestamp: block.timestamp,
                isDeposit: false,
                usdcReceived: 0
            })
        );

        emit Withdrawal(
            msg.sender,
            token,
            nativeAmount,
            valueUSD,
            userVaults[msg.sender][token]
        );

        if (token == NATIVE_ETH) {
            _transferETH(msg.sender, nativeAmount);
        } else {
            IERC20(token).safeTransfer(msg.sender, nativeAmount);
        }
    }

    /**
     * @notice Executes exact input single swap on Uniswap V4
     * @param params Swap parameters
     * @return amountOut USDC received
     */
    function _swapExactInputSingle(SwapParams memory params)
        private
        returns (uint256 amountOut)
    {
        // Record balance before swap
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        // Build swap command for UniversalRouter
        // Command: V3_SWAP_EXACT_IN = 0x00
        bytes memory commands = abi.encodePacked(bytes1(0x00));

        // Build swap path: tokenIn -> USDC
        bytes memory path;
        if (params.tokenIn == NATIVE_ETH) {
            // For ETH, use WETH in the path
            path = abi.encodePacked(
                _getWETH(),
                params.fee,
                USDC
            );
        } else {
            path = abi.encodePacked(
                params.tokenIn,
                params.fee,
                USDC
            );
        }

        // Build swap input data
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(this), // recipient
            params.amountIn,
            params.amountOutMinimum,
            path,
            true // payerIsUser
        );

        // Execute swap
        uint256 value = params.tokenIn == NATIVE_ETH ? params.amountIn : 0;
        
        try universalRouter.execute{value: value}(
            commands,
            inputs,
            block.timestamp + 300 // 5 minute deadline
        ) {
            // Calculate amount received
            uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
            amountOut = usdcAfter - usdcBefore;

            if (amountOut < params.amountOutMinimum) {
                revert KipuBankV3__InsufficientSwapOutput(
                    amountOut,
                    params.amountOutMinimum
                );
            }

            emit TokenSwapped(
                msg.sender,
                params.tokenIn,
                USDC,
                params.amountIn,
                amountOut
            );

            return amountOut;
        } catch Error(string memory reason) {
            revert KipuBankV3__SwapFailed(reason);
        } catch {
            revert KipuBankV3__SwapFailed("Unknown error");
        }
    }

    /**
     * @notice Ensures Permit2 has sufficient approval
     */
    function _ensurePermit2Approval(address token, uint256 amount) private {
        uint256 currentAllowance = IERC20(token).allowance(
            address(this),
            address(permit2)
        );

        if (currentAllowance < amount) {
            IERC20(token).safeApprove(address(permit2), 0);
            IERC20(token).safeApprove(address(permit2), type(uint256).max);
        }
    }

    /**
     * @notice Calculates minimum output with slippage
     */
    function _calculateMinimumOutput(address token, uint256 amountIn)
        private
        view
        returns (uint256)
    {
        uint256 estimatedUSD = _convertToUSD(token, amountIn);
        // Apply slippage tolerance
        uint256 minUSD = (estimatedUSD * (10000 - slippageTolerance)) / 10000;
        return minUSD;
    }

    function _getLatestPrice(address token)
        private
        view
        returns (uint256 price)
    {
        Asset memory asset = supportedAssets[token];
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            asset.priceFeed
        );

        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        if (answer <= 0) {
            revert KipuBankV3__InvalidPrice();
        }
        if (updatedAt == 0 || answeredInRound < roundId) {
            revert KipuBankV3__PriceStale();
        }
        if (block.timestamp - updatedAt > 3600) {
            revert KipuBankV3__PriceStale();
        }

        return uint256(answer);
    }

    function _convertToUSD(address token, uint256 amount)
        private
        view
        returns (uint256)
    {
        uint256 price = _getLatestPrice(token);
        Asset memory asset = supportedAssets[token];

        uint256 valueUSD8Decimals = (amount * price) / (10 ** asset.decimals);
        return valueUSD8Decimals / 100;
    }

    function _normalizeDecimals(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals
    ) private pure returns (uint256) {
        if (fromDecimals == toDecimals) {
            return amount;
        } else if (fromDecimals > toDecimals) {
            return amount / (10 ** (fromDecimals - toDecimals));
        } else {
            return amount * (10 ** (toDecimals - fromDecimals));
        }
    }

    function _validatePriceFeed(address priceFeed) private view {
        AggregatorV3Interface feed = AggregatorV3Interface(priceFeed);
        
        try feed.latestRoundData() returns (
            uint80,
            int256 answer,
            uint256,
            uint256,
            uint80
        ) {
            if (answer <= 0) {
                revert KipuBankV3__InvalidPriceFeed(priceFeed);
            }
        } catch {
            revert KipuBankV3__InvalidPriceFeed(priceFeed);
        }
    }

    function _transferETH(address recipient, uint256 amount) private {
        (bool success, ) = recipient.call{value: amount}("");
        if (!success) {
            revert KipuBankV3__TransferFailed();
        }
    }

    /**
     * @notice Returns WETH address for the current network
     */
    function _getWETH() private view returns (address) {
        // Sepolia WETH
        if (block.chainid == 11155111) {
            return 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
        }
        // Mainnet WETH
        return 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    }

    receive() external payable {}
}
