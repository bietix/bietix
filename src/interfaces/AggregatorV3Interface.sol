// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

// Se conserva el nombre estándar de Chainlink en lugar del prefijo "I".
// solhint-disable interface-starts-with-i

/// @title AggregatorV3Interface
/// @author Chainlink (interfaz pública; se conserva su nombre estándar)
/// @notice Interfaz mínima de los feeds de precio de Chainlink.
interface AggregatorV3Interface {
    /// @notice Decimales del precio.
    /// @return decimales
    function decimals() external view returns (uint8);

    /// @notice Descripción del feed (por ejemplo "BTC / USD"); se usa para verificar direcciones en las pruebas.
    /// @return descripción
    function description() external view returns (string memory);

    /// @notice Último dato del feed.
    /// @return roundId ronda (deprecado, no se usa)
    /// @return answer precio
    /// @return startedAt inicio de la ronda (en el feed del sequencer: desde cuándo está en ese estado)
    /// @return updatedAt última actualización
    /// @return answeredInRound ronda (deprecado, no se usa)
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
