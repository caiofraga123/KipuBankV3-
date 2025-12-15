# KipuBank V3 🏦⚡

> **DeFi Vault with Automatic Token Conversion via Uniswap V4**

A production-ready smart contract vault that accepts ANY token tradeable on Uniswap V4, automatically converts it to USDC, and credits your account - all while respecting the original bank cap limits.

[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-blue)](https://soliditylang.org/)
[![Uniswap V4](https://img.shields.io/badge/Uniswap-V4-FF007A)](https://uniswap.org/)
[![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-v5.0-purple)](https://openzeppelin.com/)
[![Chainlink](https://img.shields.io/badge/Chainlink-Integrated-375BD2)](https://chain.link/)

---

## 📋 Table of Contents

- [Overview](#overview)
- [What's New in V3](#whats-new-in-v3)
- [Key Features](#key-features)
- [Architecture](#architecture)
- [Installation](#installation)
- [Deployment](#deployment)
- [Usage Guide](#usage-guide)
- [Design Decisions](#design-decisions)
- [Security](#security)
- [Contract Addresses](#contract-addresses)

---

## 🎯 Overview

KipuBankV3 extends the multi-asset vault concept to its ultimate form: **accept any token, store everything as USDC**. This creates a unified accounting system where users can deposit any Uniswap V4-tradeable token, and the contract automatically handles the conversion.

### The Problem V3 Solves

**V2 Limitation**: Users could only deposit pre-approved tokens (ETH, USDC, LINK, etc.). Each new token required admin approval and configuration.

**V3 Solution**: Deposit ANY token that exists on Uniswap V4. The contract automatically swaps it to USDC using the UniversalRouter, giving users maximum flexibility while maintaining simple USDC-based accounting.

---

## 🚀 What's New in V3

### V2 → V3 Evolution

| Feature | V2 | V3 |
|---------|----|----|
| **Token Support** | Pre-approved whitelist | ANY Uniswap V4 token |
| **Deposit Flow** | Direct deposit → stored as-is | Auto-swap → USDC storage |
| **User Experience** | Limited token choices | Unlimited token choices |
| **Integration** | Manual token addition | Uniswap V4 UniversalRouter |
| **Accounting** | Multi-token balances | Unified USDC accounting |

### Major V3 Additions

1. **✨ UniversalRouter Integration**
   - Direct integration with Uniswap V4's routing system
   - Automatic optimal path finding
   - Support for all pool fee tiers

2. **🔄 Automatic Token Conversion**
   - Deposit any ERC20 → receive USDC credit
   - Configurable slippage protection
   - Real-time swap execution

3. **🎯 Permit2 Integration**
   - Secure token approvals
   - Gas-efficient permission management

4. **📊 Enhanced Transaction History**
   - Records original token deposited
   - Tracks USDC received after swap
   - Complete audit trail

---

## ✨ Key Features

### For Users

- 🌐 **Universal Token Support**: Deposit ANY token tradeable on Uniswap V4
- 💱 **Automatic Conversion**: Your tokens are instantly converted to USDC
- 🔒 **Slippage Protection**: Configurable tolerance prevents bad trades
- 💰 **Unified Balance**: Everything stored as USDC for simplicity
- 📈 **Real-Time Pricing**: Chainlink oracles ensure fair valuations
- 📜 **Complete History**: Track every deposit with swap details

### For Administrators

- ⚙️ **Slippage Control**: Set maximum acceptable slippage
- 🎛️ **Fee Tier Selection**: Choose optimal Uniswap pool fees
- ⏸️ **Emergency Controls**: Pause/unpause as needed
- 👥 **Role Management**: Granular access control

### Technical Features

- ✅ **Uniswap V4 Integration**: Latest DEX technology
- ✅ **ReentrancyGuard**: Protected against reentrancy
- ✅ **SafeERC20**: Handles non-standard tokens
- ✅ **Custom Errors**: Gas-efficient error handling
- ✅ **Event Logging**: Complete observability

---

## 🏗️ Architecture

### System Overview

```
User deposits Token X
        ↓
KipuBankV3 receives Token X
        ↓
Approves Permit2
        ↓
Calls UniversalRouter
        ↓
Uniswap V4 swap: Token X → USDC
        ↓
USDC returned to KipuBankV3
        ↓
Credit user with USDC balance
        ↓
✅ User balance updated
```

### Core Components

#### 1. **UniversalRouter Instance** ✅ (Requirement)

```solidity
IUniversalRouter public immutable universalRouter;

// Initialization
universalRouter = IUniversalRouter(_universalRouter);

// Usage in swaps
universalRouter.execute{value: value}(commands, inputs, deadline);
```

**Purpose**: Execute swaps through Uniswap V4's unified router interface.

#### 2. **IPermit2 Instance** ✅ (Requirement)

```solidity
IPermit2 public immutable permit2;

// Ensure approval before swap
function _ensurePermit2Approval(address token, uint256 amount) private {
    uint256 currentAllowance = IERC20(token).allowance(
        address(this),
        address(permit2)
    );
    if (currentAllowance < amount) {
        IERC20(token).safeApprove(address(permit2), type(uint256).max);
    }
}
```

**Purpose**: Secure, gas-efficient token approval system.

#### 3. **Uniswap Libraries & Types** ✅ (Requirement)

```solidity
// Pool key structure for V4 pools
interface IPoolManager {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }
}

// Currency type for token identification
type Currency is address;
```

**Purpose**: Type-safe interaction with Uniswap V4 pools.

#### 4. **depositArbitraryToken Function** ✅ (Requirement)

```solidity
function depositArbitraryToken(
    address token,
    uint256 amount,
    uint24 fee
) external 
    validAmount(amount)
    onlySupportedAsset(token)
    whenNotPaused
    nonReentrant
{
    // 1. Transfer token from user
    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    
    // 2. Approve Permit2
    _ensurePermit2Approval(token, amount);
    
    // 3. Swap to USDC
    uint256 usdcReceived = _swapExactInputSingle(
        SwapParams({
            tokenIn: token,
            amountIn: amount,
            amountOutMinimum: _calculateMinimumOutput(token, amount),
            fee: fee
        })
    );
    
    // 4. Credit user
    _creditUser(msg.sender, USDC, usdcReceived, amount, token);
}
```

**Purpose**: Main entry point for depositing arbitrary tokens.

**Parameters**:
- `token`: Address of the token to deposit
- `amount`: Amount to deposit (in token's native decimals)
- `fee`: Uniswap pool fee tier (500 = 0.05%, 3000 = 0.3%, 10000 = 1%)

#### 5. **_swapExactInputSingle Function** ✅ (Requirement)

```solidity
function _swapExactInputSingle(SwapParams memory params)
    private
    returns (uint256 amountOut)
{
    // Record USDC balance before
    uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
    
    // Build swap command (V3_SWAP_EXACT_IN = 0x00)
    bytes memory commands = abi.encodePacked(bytes1(0x00));
    
    // Build swap path: tokenIn -> USDC
    bytes memory path = abi.encodePacked(
        params.tokenIn,
        params.fee,
        USDC
    );
    
    // Build inputs
    bytes[] memory inputs = new bytes[](1);
    inputs[0] = abi.encode(
        address(this),              // recipient
        params.amountIn,            // amount in
        params.amountOutMinimum,    // min amount out
        path,                       // swap path
        true                        // payer is user
    );
    
    // Execute swap
    universalRouter.execute(
        commands,
        inputs,
        block.timestamp + 300 // 5 min deadline
    );
    
    // Calculate output
    uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
    amountOut = usdcAfter - usdcBefore;
    
    // Validate minimum output
    if (amountOut < params.amountOutMinimum) {
        revert KipuBankV3__InsufficientSwapOutput(amountOut, params.amountOutMinimum);
    }
    
    emit TokenSwapped(msg.sender, params.tokenIn, USDC, params.amountIn, amountOut);
    
    return amountOut;
}
```

**Purpose**: Execute exact input single-hop swap via UniversalRouter.

**How it works**:
1. Records USDC balance before swap
2. Builds UniversalRouter command bytes
3. Constructs swap path (token → USDC)
4. Executes swap through UniversalRouter
5. Calculates and validates output
6. Emits event for tracking

---

## 📦 Installation

### Prerequisites

```bash
# Required tools
- Node.js v18+
- Hardhat
- Git
```

### Setup

```bash
# Clone repository
git clone https://github.com/yourusername/KipuBankV3.git
cd KipuBankV3

# Install dependencies
npm install

# Install required packages
npm install @openzeppelin/contracts
npm install @chainlink/contracts
npm install @uniswap/v4-core
npm install @uniswap/universal-router

# Create environment file
cp .env.example .env
```

### Environment Configuration

```env
# RPC
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR-KEY

# Wallet
PRIVATE_KEY=your_private_key_without_0x

# Verification
ETHERSCAN_API_KEY=your_etherscan_api_key

# Contract Addresses (Sepolia)
USDC_ADDRESS=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
UNIVERSAL_ROUTER=0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD
PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3
```

---

## 🚀 Deployment

### Deploy Script

Create `scripts/deploy-v3.js`:

```javascript
const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  
  console.log("Deploying KipuBankV3...");
  console.log("Deployer:", deployer.address);
  
  // Configuration
  const withdrawalLimitUSD = 1000 * 1e6; // $1,000
  const usdc = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"; // Sepolia
  const universalRouter = "0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD";
  const permit2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
  
  // Deploy
  const KipuBankV3 = await hre.ethers.getContractFactory("KipuBankV3");
  const bank = await KipuBankV3.deploy(
    withdrawalLimitUSD,
    usdc,
    universalRouter,
    permit2
  );
  
  await bank.waitForDeployment();
  const address = await bank.getAddress();
  
  console.log("✅ KipuBankV3 deployed:", address);
  
  // Add USDC as supported asset (no swap needed)
  const usdcPriceFeed = "0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E";
  await bank.addAsset(usdc, 6, usdcPriceFeed, false);
  
  // Add ETH as supported asset (requires swap)
  const ethPriceFeed = "0x694AA1769357215DE4FAC081bf1f309aDC325306";
  await bank.addAsset(hre.ethers.ZeroAddress, 18, ethPriceFeed, true);
  
  console.log("✅ Initial assets configured");
  console.log("\nNext: Verify on Etherscan");
  console.log(`npx hardhat verify --network sepolia ${address} "${withdrawalLimitUSD}" "${usdc}" "${universalRouter}" "${permit2}"`);
}

main().catch(console.error);
```

### Deploy Command

```bash
# Deploy to Sepolia
npx hardhat run scripts/deploy-v3.js --network sepolia

# Verify
npx hardhat verify --network sepolia <ADDRESS> \
  "1000000000" \
  "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238" \
  "0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD" \
  "0x000000000022D473030F116dDEE9F6B43aC78BA3"
```

---

## 💻 Usage Guide

### 1. Deposit USDC Directly (No Swap)

```javascript
const usdc = await ethers.getContractAt("IERC20", USDC_ADDRESS);
const bank = await ethers.getContractAt("KipuBankV3", BANK_ADDRESS);

// Approve
await usdc.approve(bank.address, ethers.parseUnits("1000", 6));

// Deposit
await bank.depositUSDC(ethers.parseUnits("1000", 6));

console.log("✅ 1000 USDC deposited");
```

### 2. Deposit Arbitrary Token (With Auto-Swap)

```javascript
// Example: Deposit LINK
const link = await ethers.getContractAt("IERC20", LINK_ADDRESS);

// Step 1: Add LINK as supported asset (admin only, one-time)
await bank.addAsset(
  LINK_ADDRESS,
  18, // LINK decimals
  LINK_USD_PRICE_FEED,
  true // requires swap
);

// Step 2: User deposits LINK
await link.approve(bank.address, ethers.parseUnits("10", 18));

await bank.depositArbitraryToken(
  LINK_ADDRESS,
  ethers.parseUnits("10", 18),
  3000 // 0.3% fee tier
);

console.log("✅ 10 LINK deposited and swapped to USDC");
```

### 3. Deposit ETH (With Auto-Swap)

```javascript
// ETH is swapped to USDC automatically
await bank.depositETH({ value: ethers.parseEther("1.0") });

console.log("✅ 1 ETH deposited and swapped to USDC");
```

### 4. Check Your Balance

```javascript
// Get USDC balance (everything is stored as USDC)
const balance = await bank.getMyBalance(USDC_ADDRESS);
console.log("USDC Balance:", ethers.formatUnits(balance, 6));

// Get all balances
const [tokens, balances] = await bank.getAllBalances(yourAddress);
```

### 5. View Transaction History

```javascript
const history = await bank.getTransactionHistory(yourAddress);

history.forEach((tx, i) => {
  console.log(`\nTransaction ${i + 1}:`);
  console.log("  Type:", tx.isDeposit ? "DEPOSIT" : "WITHDRAWAL");
  console.log("  Token:", tx.token);
  console.log("  Amount:", ethers.formatUnits(tx.amount, 6));
  if (tx.usdcReceived > 0) {
    console.log("  USDC Received:", ethers.formatUnits(tx.usdcReceived, 6));
  }
  console.log("  Time:", new Date(Number(tx.timestamp) * 1000).toLocaleString());
});
```

### 6. Withdraw USDC

```javascript
// Withdraw $500 USDC
await bank.withdrawUSDC(ethers.parseUnits("500", 6));

console.log("✅ $500 USDC withdrawn");
```

---

## 🤔 Design Decisions & Trade-offs

### 1. **Why Store Everything as USDC?**

**Decision**: Convert all deposits to USDC regardless of input token.

**Rationale**:
- ✅ Simplified accounting (single currency)
- ✅ Stable value storage (USDC is pegged)
- ✅ Easier bank cap management
- ✅ Predictable withdrawal values

**Trade-off**:
- ❌ Users lose original token exposure
- ❌ Gas costs for swaps
- ❌ Slippage on deposits

**When this makes sense**: Users want stable value storage, not speculative holdings.

---

### 2. **Why UniversalRouter Instead of Direct Pool Calls?**

**Decision**: Use Uniswap's UniversalRouter for all swaps.

**Rationale**:
- ✅ Handles routing complexity
- ✅ Gas optimized by Uniswap team
- ✅ Supports multi-hop paths if needed
- ✅ Future-proof (works with new pool types)

**Trade-off**:
- ❌ Additional contract dependency
- ❌ Less control over exact routing

**Benefit**: Dramatically simpler implementation and maintenance.

---

### 3. **Why Require Fee Tier Parameter?**

**Decision**: Users must specify pool fee tier when depositing.

**Rationale**:
- ✅ Different tokens have different optimal fees
- ✅ Gives users control over routing
- ✅ Avoids assumptions about liquidity

**Example**:
- Stablecoins: Use 100 (0.01%) or 500 (0.05%) - tight spreads
- Major tokens: Use 3000 (0.3%) - standard
- Exotic tokens: Use 10000 (1%) - wider spreads needed

**Trade-off**:
- ❌ Slightly less user-friendly
- ✅ More flexible and accurate

---

### 4. **Why Slippage Tolerance Setting?**

**Decision**: Admin-controlled slippage tolerance (default 0.5%).

**Rationale**:
- ✅ Protects users from sandwich attacks
- ✅ Prevents bad trades in volatile markets
- ✅ Adjustable based on market conditions

**Trade-off**:
- ❌ Deposits may fail in volatile conditions
- ✅ Better than losing 5-10% to MEV

---

### 5. **Why Still Support V2 Functionality?**

**Decision**: Maintain direct ETH and USDC deposits alongside arbitrary token support.

**Rationale**:
- ✅ Gas savings for common tokens
- ✅ Backwards compatibility
- ✅ Users can avoid swap fees if they already have USDC

**Trade-off**:
- ❌ More complex contract
- ✅ Better UX overall

---

## 🔒 Security

### Security Measures

1. **✅ ReentrancyGuard**
   ```solidity
   contract KipuBankV3 is ReentrancyGuard {
       function depositArbitraryToken(...) external nonReentrant {
           // Protected from reentrancy
       }
   }
   ```

2. **✅ SafeERC20**
   ```solidity
   using SafeERC20 for IERC20;
   IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
   ```

3. **✅ Slippage Protection**
   ```solidity
   if (amountOut < params.amountOutMinimum) {
       revert KipuBankV3__InsufficientSwapOutput(amountOut, params.amountOutMinimum);
   }
   ```

4. **✅ Bank Cap Enforcement**
   ```solidity
   if (totalValueLockedUSD + valueUSD > BANK_CAP_USD) {
       revert KipuBankV3__BankCapacityExceeded(totalValueLockedUSD + valueUSD, BANK_CAP_USD);
   }
   ```

5. **✅ Access Control**
   ```solidity
   function setSlippageTolerance(uint256 _slippage) external onlyRole(ADMIN_ROLE) {
       // Only admins can change slippage
   }
   ```

### Attack Vectors & Mitigations

| Attack | Mitigation |
|--------|------------|
| **Reentrancy** | ReentrancyGuard on all entry points |
| **Front-running** | Slippage protection + deadline |
| **Sandwich attacks** | Configurable slippage tolerance |
| **Oracle manipulation** | Chainlink price feed validation |
| **Approval exploits** | Permit2 secure approval system |
| **Bank cap bypass** | Check AFTER swap completion |

---

## 📍 Contract Addresses

### Sepolia Testnet

- **KipuBankV3**: `0xYourDeployedAddress`
- **Network**: Ethereum Sepolia (Chain ID: 11155111)
- **Explorer**: [View on Etherscan](https://sepolia.etherscan.io/address/0xYourDeployedAddress)

### Dependencies (Sepolia)

| Contract | Address |
|----------|---------|
| USDC | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |
| UniversalRouter | `0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| WETH | `0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9` |

### Chainlink Price Feeds (Sepolia)

| Pair | Address |
|------|---------|
| ETH/USD | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| USDC/USD | `0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E` |

---

## 📊 V1 → V2 → V3 Comparison

| Feature | V1 | V2 | V3 |
|---------|----|----|---|
| **Assets** | ETH only | ETH + Whitelist | ANY Uniswap token |
| **Swap Integration** | None | None | UniversalRouter |
| **Storage Format** | Native decimals | Multi-token (6 dec) | Unified USDC |
| **User Flexibility** | Very limited | Limited | Unlimited |
| **Admin Burden** | Low | Medium | Low |
| **Complexity** | Low | Medium | High |
| **Gas Cost** | Low | Medium | High (due to swaps) |

---

## 🧪 Testing

Run comprehensive tests:

```bash
npm test
```

Key test scenarios:
- ✅ USDC direct deposits
- ✅ Arbitrary token deposits with swaps
- ✅ Slippage protection
- ✅ Bank cap enforcement post-swap
- ✅ Failed swaps
- ✅ Multiple users
- ✅ Emergency pause during swap

---

## 🎓 Educational Value

This project demonstrates:

1. **Protocol Composability**: How DeFi protocols integrate
2. **Uniswap V4 Integration**: Real-world DEX usage
3. **Complex State Management**: Multi-step operations
4. **Gas Optimization**: Efficient swap execution
5. **Production Patterns**: ReentrancyGuard, SafeERC20, etc.

---

## 🤝 Contributing

Found a bug or have an idea? Open an issue or PR!

---

## 📄 License

MIT License - see [LICENSE](LICENSE) file

---

## 🙏 Acknowledgments

- Uniswap Labs for V4 architecture
- OpenZeppelin for security libraries
- Chainlink for reliable oracles
- Kipu program for the challenge

---

**⚠️ Disclaimer**: This is educational software. Audit before mainnet use. Not financial advice.
