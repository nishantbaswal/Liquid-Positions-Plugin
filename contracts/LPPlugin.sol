// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

// Core libraries and abstract plugin contract for Algebra protocol
import "@cryptoalgebra/abstract-plugin/contracts/AbstractPlugin.sol";
import "@cryptoalgebra/integral-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@cryptoalgebra/integral-periphery/contracts/libraries/PoolInteraction.sol";
import "@cryptoalgebra/integral-periphery/contracts/libraries/PoolAddress.sol";
import "@cryptoalgebra/integral-periphery/contracts/libraries/LiquidityAmounts.sol";
import "@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol";
import "@cryptoalgebra/integral-core/contracts/libraries/TickMath.sol";
import "@cryptoalgebra/integral-core/contracts/libraries/Plugins.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/interfaces/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import "./LPCallback.sol";
import {ILPToken} from "./interfaces/ILPToken.sol";
import {ILPTokenFactory} from "./interfaces/ILPTokenFactory.sol";

/// @title LPPlugin
/// @notice Plugin to manage LPToken representations of NFT positions in Algebra
contract LPPlugin is AbstractPlugin, IERC721Receiver, ReentrancyGuard {
    event TokenCreated(int24 tickLower, int24 tickUpper, address addr);
    event FeeRateUpdated(uint24 newFeeRate);
    event TrustedNFTManagerUpdated(address indexed manager, bool trusted);

    struct CollectParams {
        address recipient;
        int24 tickLower;
        int24 tickUpper;
        uint256 lpTokensToBurn;
        uint256 totalSupplyBeforeBurn;
    }

    struct Cache {
        uint256 initialValue;
        uint160 price;
    }

    /// @notice Default plugin configuration flag - includes position hooks, swap hooks, and dynamic fee capability
    uint8 public constant override defaultPluginConfig =
        uint8(
            Plugins.AFTER_POSITION_MODIFY_FLAG |
                Plugins.BEFORE_SWAP_FLAG |
                Plugins.BEFORE_POSITION_MODIFY_FLAG
        );

    // Plugin state variables
    mapping(int24 => mapping(int24 => address)) public lpTokenByTicks; // Maps tick ranges to LPToken addresses

    /// @notice Allowlist of trusted NonfungiblePositionManager contracts
    mapping(address => bool) public trustedNFTManagers;

    uint256 private constant INITIAL_LP_TOKEN_TO_MINT = 10 ** 32;

    /// @notice Plugin fee in PPM (parts per million, e.g., 10000 = 1%)
    uint24 public pluginFeeRate;
    Cache private _cache;

    address public immutable callback;

    /// @notice Constructor initializing pool and plugin factory
    constructor(
        address _pool,
        address _pluginFactory
    ) AbstractPlugin(_pool, _pluginFactory) {
        callback = address(
            new LPCallback(_pool, _pluginFactory, address(this))
        );
        // Initialize with a default plugin fee as of PPM
        // Perhaps redundant with the fee managing of the fee in the factory
        pluginFeeRate = 50000;
        emit FeeRateUpdated(pluginFeeRate);
    }

    /// @notice Parses calldata to extract the payer address
    /// @dev data is abi.encode(MintCallbackData({PoolAddress.PoolKey poolKey, address payer}));
    function parseCalldata(bytes memory data) internal pure returns (address) {
        (, address payer) = abi.decode(data, (PoolAddress.PoolKey, address));
        return payer;
    }

    /// @notice Called for plugin initialization
    /// @dev Sets default plugin flags
    function beforeInitialize(
        address,
        uint160
    ) external override onlyPool returns (bytes4) {
        _updatePluginConfigInPool(defaultPluginConfig);
        return IAlgebraPlugin.beforeInitialize.selector;
    }

    function beforeModifyPosition(
        address,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 deltaL,
        bytes calldata
    ) external virtual override onlyPool returns (bytes4, uint24) {
        if (owner == address(this) && deltaL > 0) {
            (uint160 price, , , ) = _getPoolState();
            _cache = Cache({
                initialValue: positionValue(tickLower, tickUpper, price),
                price: price
            });
        }
        return (IAlgebraPlugin.beforeModifyPosition.selector, 0);
    }

    function afterModifyPosition(
        address,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 deltaL,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override onlyPool returns (bytes4) {
        if (owner == address(this) && deltaL > 0) {
            _mintLPTokens(
                parseCalldata(data),
                tickLower,
                tickUpper,
                amount0,
                amount1
            );
        }

        return IAlgebraPlugin.afterModifyPosition.selector;
    }

    function beforeSwap(
        address,
        address,
        bool,
        int256,
        uint160,
        bool,
        bytes calldata
    ) external virtual override onlyPool returns (bytes4, uint24, uint24) {
        uint24 fee;
        try IAlgebraPool(pool).fee() {
            fee = SafeCast.toUint24(
                Math.mulDiv(IAlgebraPool(pool).fee(), pluginFeeRate, 10 ** 6)
            );
        } catch {
            (, , uint16 baseFee, ) = _getPoolState();
            fee = SafeCast.toUint24(
                Math.mulDiv(baseFee, pluginFeeRate, 10 ** 6)
            );
        }
        return (IAlgebraPlugin.beforeSwap.selector, 0, fee);
    }

    function withdraw(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 lpTokensToBurn
    ) public nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(lpTokensToBurn > 0, "Invalid LP tokens value");

        ILPToken lpToken = ILPToken(lpTokenByTicks[tickLower][tickUpper]);
        uint256 totalSupplyBeforeBurn = lpToken.totalSupply();
        _burnLPTokens(msg.sender, lpToken, lpTokensToBurn);

        (amount0, amount1) = _collect(
            CollectParams(recipient, tickLower, tickUpper, lpTokensToBurn, totalSupplyBeforeBurn)
        );
    }

    /// @notice Burns LP tokens for a user
    /// @param user Address of the LPToken holder
    /// @param lpToken LP Token instance
    /// @param lpTokensToBurn Amount of LP tokens to burn
    // laovra quinp
    function _burnLPTokens(
        address user,
        ILPToken lpToken,
        uint128 lpTokensToBurn
    ) private {
        require(
            lpToken.balanceOf(user) >= uint256(lpTokensToBurn),
            "Insufficient balance to burn"
        );

        lpToken.burn(user, uint256(lpTokensToBurn));
    }

    /// @notice Calculate the pre-value of the existing position including fees and reserves
    /// @param feeToken0 Fees accrued in token0
    /// @param feeToken1 Fees accrued in token1
    /// @param tokenReserve0 Current reserve of token0 in the position
    /// @param tokenReserve1 Current reserve of token1 in the position
    /// @return preValue The total value of the position in terms of token1 equivalent

    /// @dev This function is required by AbstractPlugin.sol
    function _authorize() internal view override {
        require(msg.sender == pluginFactory, "Unauthorized");
    }

    /// @notice Set the plugin fee rate (only callable by factory)
    /// @param newFeeRate New fee rate in basis points (10000 = 1%)
    function setPluginFeeRate(uint24 newFeeRate) external {
        _authorize();
        require(newFeeRate < 250000, "Fee rate too high");
        pluginFeeRate = newFeeRate;
    }

    /// @notice Add or remove a trusted NonfungiblePositionManager (only callable by factory)
    /// @param manager Address of the position manager contract
    /// @param trusted Whether the manager should be trusted
    function setTrustedNFTManager(address manager, bool trusted) external {
        _authorize();
        trustedNFTManagers[manager] = trusted;
        emit TrustedNFTManagerUpdated(manager, trusted);
    }

    /// @notice ERC721 callback to allow plugin to receive NFT
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        (uint256 min0, uint256 min1) = abi.decode(data, (uint256, uint256));

        (
            ,
            ,
            address token0,
            address token1,
            ,
            int24 tickLower,
            int24 tickUpper,
            uint128 userLiquidity,
            ,
            ,
            ,

        ) = INonfungiblePositionManager(msg.sender).positions(tokenId);

        require(
            token0 == IAlgebraPool(pool).token0() &&
                token1 == IAlgebraPool(pool).token1(),
            "Tokens do not match"
        );

        // Decrease liquidity from user's latest NFT
        (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(msg.sender)
            .decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: userLiquidity,
                    amount0Min: min0,
                    amount1Min: min1,
                    deadline: block.timestamp + 10 minutes
                })
            );

        // Collect tokens from the NFT
        (amount0, amount1) = INonfungiblePositionManager(msg.sender).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: uint128(amount0),
                amount1Max: uint128(amount1)
            })
        );
        INonfungiblePositionManager(msg.sender).burn(tokenId);

        // Approve tokens for reinvestment
        require(
            IERC20(IAlgebraPool(pool).token0()).approve(callback, amount0),
            "Token0 approval failed"
        );
        require(
            IERC20(IAlgebraPool(pool).token1()).approve(callback, amount1),
            "Token1 approval failed"
        );

        address lpTokenAddress = lpTokenByTicks[tickLower][tickUpper];

        uint256 currentAmount = lpTokenAddress != address(0)
            ? ILPToken(lpTokenAddress).balanceOf(address(this))
            : 0;

        ILPCallback(callback).mint(from, tickLower, tickUpper, amount0, amount1);

        require(
            ILPToken(lpTokenByTicks[tickLower][tickUpper]).transfer(
                from,
                ILPToken(lpTokenByTicks[tickLower][tickUpper]).balanceOf(
                    address(this)
                ) - currentAmount
            ),
            "Transfer failed"
        );

        return IERC721Receiver.onERC721Received.selector;
    }

    function convertToken0ToToken1(
        uint256 amount0,
        uint160 price
    ) public pure returns (uint256 token0InToken1) {
        if (amount0 > 0 && price > 0) {
            // Use Math.mulDiv to prevent overflow in multiplication and handle division by 2^96
            token0InToken1 = Math.mulDiv(amount0, uint256(price), 2 ** 96);
        } else {
            token0InToken1 = 0;
        }
    }

    function positionValue(
        int24 tickLower,
        int24 tickUpper,
        uint160 price
    ) public view returns (uint256 value) {
        (uint256 liquidity, , , uint128 fees0, uint128 fees1) = IAlgebraPool(
            pool
        ).positions(getPositionKey(address(this), tickLower, tickUpper));
        (uint256 amount0, uint256 amount1) = LiquidityAmounts
            .getAmountsForLiquidity(
                price,
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                SafeCast.toUint128(liquidity)
            );
        value = amount1 + fees1 + convertToken0ToToken1(amount0 + fees0, price);
    }

    function _mintLPTokens(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) private {
        address lpTokenAddress = lpTokenByTicks[tickLower][tickUpper];
        uint256 lpTokensToMint;
        ILPToken lpToken;

        if (lpTokenAddress == address(0)) {
            string memory tokenName = string.concat(
                IERC20Metadata(IAlgebraPool(pool).token0()).symbol(),
                "-",
                IERC20Metadata(IAlgebraPool(pool).token1()).symbol(),
                " ",
                Strings.toStringSigned(int256(tickLower)),
                "-",
                Strings.toStringSigned(int256(tickUpper))
            );
            address newTokenAddress = ILPTokenFactory(
                ILPPluginFactory(pluginFactory).lpTokenFactory()
            ).create(string.concat("LPToken ", tokenName), tokenName);
            lpToken = ILPToken(newTokenAddress);

            emit TokenCreated(tickLower, tickUpper, newTokenAddress);
            lpTokenByTicks[tickLower][tickUpper] = newTokenAddress;
            lpTokensToMint = INITIAL_LP_TOKEN_TO_MINT;
        } else {
            lpToken = ILPToken(lpTokenAddress);
            uint256 totalSupply = lpToken.totalSupply();

            // Calculate delta value: deltaY + deltaX * P (safe fixed-point arithmetic)
            // deltaY = amount0 (token1 being deposited)
            // deltaX = depositAmount0 (token0 being deposited)
            uint256 userValue = amount1 +
                convertToken0ToToken1(amount0, _cache.price);

            // Apply the formula: lpTokensToMint = (deltaValue * totalSupply) / preValue
            if (_cache.initialValue > 0 && totalSupply > 0) {
                lpTokensToMint = Math.mulDiv(
                    userValue,
                    totalSupply,
                    _cache.initialValue
                );
            } else {
                // Fallback for edge cases (first deposit, zero pre-value, etc.)
                lpTokensToMint = INITIAL_LP_TOKEN_TO_MINT;
            }
            // Ensure minimum lpToken amount to prevent zero minting
            if (lpTokensToMint == 0 && userValue > 0) {
                lpTokensToMint = 1;
            }
        }
        // Mint proportional lptoken to user
        lpToken.mint(recipient, lpTokensToMint);
    }

    function getPositionKey(
        address owner,
        int24 bottomTick,
        int24 topTick
    ) internal pure returns (bytes32 key) {
        assembly {
            key := or(
                shl(24, or(shl(24, owner), and(bottomTick, 0xFFFFFF))),
                and(topTick, 0xFFFFFF)
            )
        }
    }

    function _collect(
        CollectParams memory params
    ) private returns (uint256 amount0, uint256 amount1) {
        (uint256 liquidity, , , , ) = IAlgebraPool(pool).positions(
            getPositionKey(address(this), params.tickLower, params.tickUpper)
        );

        (uint256 lAmount0, uint256 lAmount1) = IAlgebraPool(pool).burn(
            params.tickLower,
            params.tickUpper,
            SafeCast.toUint128(
                Math.mulDiv(
                    params.lpTokensToBurn,
                    SafeCast.toUint128(liquidity),
                    params.totalSupplyBeforeBurn
                )
            ),
            abi.encode(0)
        );

        (, , , uint128 fees0, uint128 fees1) = IAlgebraPool(pool).positions(
            getPositionKey(address(this), params.tickLower, params.tickUpper)
        );

        (amount0, amount1) = IAlgebraPool(pool).collect(
            params.recipient,
            params.tickLower,
            params.tickUpper,
            SafeCast.toUint128(lAmount0) +
                SafeCast.toUint128(
                    Math.mulDiv(
                        params.lpTokensToBurn,
                        (fees0 - lAmount0),
                        params.totalSupplyBeforeBurn
                    )
                ),
            SafeCast.toUint128(lAmount1) +
                SafeCast.toUint128(
                    Math.mulDiv(
                        params.lpTokensToBurn,
                        (fees1 - lAmount1),
                        params.totalSupplyBeforeBurn
                    )
                )
        );
    }
}
