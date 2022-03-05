// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "contracts/interfaces/IMain.sol";
import "contracts/p0/Main.sol";
import "contracts/libraries/Fixed.sol";

contract MainCallerMockP0 {
    IMain main;

    constructor(IMain main_) {
        main = main_;
    }

    function seizeRSR(uint256 amount) external {
        main.stRSR().seizeRSR(amount);
    }

    function paused() external returns (bool) {
        return main.paused();
    }

    function fullyCapitalized() external view returns (bool) {
        return main.basketHandler().fullyCapitalized();
    }

    function status() external view returns (CollateralStatus) {
        return main.basketHandler().status();
    }

    function rsr() external view returns (IERC20) {
        return main.rsr();
    }
}