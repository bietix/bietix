// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

// ════════════════════════════════════════════════════════════════════════════
//  SOLO PARA TESTNET. Nada de este archivo se despliega en mainnet.
// ════════════════════════════════════════════════════════════════════════════

/// @notice Token de prueba con canilla (faucet) pública y acuñadores autorizados (el DEX de prueba).
contract TestnetToken is ERC20, Ownable {
    uint8 private immutable _dec;
    uint256 public immutable FAUCET_AMOUNT;
    uint256 public constant FAUCET_COOLDOWN = 1 hours;

    mapping(address => bool) public isMinter;
    mapping(address => uint256) public lastFaucet;

    error FaucetCooldown();
    error NotMinter();

    constructor(string memory n, string memory s, uint8 d, uint256 faucetAmount, address owner_)
        ERC20(n, s)
        Ownable(owner_)
    {
        _dec = d;
        FAUCET_AMOUNT = faucetAmount;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    /// @notice Cualquiera puede pedir tokens de prueba una vez por hora.
    function faucet() external {
        if (block.timestamp < lastFaucet[msg.sender] + FAUCET_COOLDOWN) revert FaucetCooldown();
        lastFaucet[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
    }

    function setMinter(address minter, bool allowed) external onlyOwner {
        isMinter[minter] = allowed;
    }

    function mint(address to, uint256 amount) external {
        if (!isMinter[msg.sender] && msg.sender != owner()) revert NotMinter();
        _mint(to, amount);
    }
}

/// @notice Feed de precio de prueba. El dueño fija el precio (para simulacros: depeg, caídas, etc.).
///         Cualquiera puede "refrescarlo" (misma respuesta, fecha actual) para que no quede viejo.
contract TestnetAggregator is AggregatorV3Interface, Ownable {
    uint8 public override decimals;
    string public override description;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public roundId;

    constructor(uint8 d, string memory desc, int256 a, address owner_) Ownable(owner_) {
        decimals = d;
        description = desc;
        answer = a;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        roundId = 1;
    }

    function setAnswer(int256 a) external onlyOwner {
        answer = a;
        updatedAt = block.timestamp;
        roundId++;
    }

    /// @notice Para el feed del sequencer: 0 = activo, 1 = caído; `since` = desde cuándo.
    function setStatus(int256 a, uint256 since) external onlyOwner {
        answer = a;
        startedAt = since;
        updatedAt = block.timestamp;
        roundId++;
    }

    function refresh() external {
        updatedAt = block.timestamp;
        roundId++;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, roundId);
    }
}

/// @notice DEX de prueba: cambia cualquier token del sistema por otro al precio de los feeds de prueba,
///         menos un spread. Acuña el token de salida (por eso necesita ser minter de los tokens).
contract TestnetDex is Ownable {
    struct PriceSource {
        AggregatorV3Interface feed; // precio en USD
        AggregatorV3Interface ratio; // opcional: multiplica (ej. WBTC/BTC)
    }

    uint256 public spreadBps = 10; // 0,10%
    mapping(address => PriceSource) public priceSource;

    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    error UnknownToken(address token);
    error Slippage(uint256 out, uint256 minOut);

    constructor(address owner_) Ownable(owner_) {}

    function setToken(address token, AggregatorV3Interface feed, AggregatorV3Interface ratio)
        external
        onlyOwner
    {
        priceSource[token] = PriceSource(feed, ratio);
    }

    function setSpread(uint256 bps) external onlyOwner {
        require(bps <= 1_000, "spread maximo 10%");
        spreadBps = bps;
    }

    /// @notice Cotización: cuánto `tokenOut` se recibe por `amountIn` de `tokenIn`.
    function quote(address tokenIn, uint256 amountIn, address tokenOut) public view returns (uint256) {
        uint256 usd = Math.mulDiv(amountIn, price(tokenIn), 10 ** ERC20(tokenIn).decimals());
        uint256 out = Math.mulDiv(usd, 10 ** ERC20(tokenOut).decimals(), price(tokenOut));
        return out * (10_000 - spreadBps) / 10_000;
    }

    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 minOut, address to)
        external
        returns (uint256 out)
    {
        out = quote(tokenIn, amountIn, tokenOut);
        if (out < minOut) revert Slippage(out, minOut);
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "transferFrom");
        TestnetToken(tokenOut).mint(to, out);
        emit Swapped(tokenIn, tokenOut, amountIn, out);
    }

    /// @notice Precio en USD con 18 decimales.
    function price(address token) public view returns (uint256 p) {
        PriceSource memory src = priceSource[token];
        if (address(src.feed) == address(0)) revert UnknownToken(token);
        p = _read(src.feed);
        if (address(src.ratio) != address(0)) p = p * _read(src.ratio) / 1e18;
    }

    function _read(AggregatorV3Interface f) internal view returns (uint256) {
        (, int256 a,,,) = f.latestRoundData();
        require(a > 0, "precio invalido");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(a) * 10 ** (18 - f.decimals());
    }
}
