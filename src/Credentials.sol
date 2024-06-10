// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract LoyaltyCredentials is ERC1155, Ownable {
    uint256 public constant LIQUIDITY_LICENSE = 1;
    uint256 public constant KYC_CREDENTIAL = 2;

    constructor() ERC1155("https://hookincubator/api/{id}.json") Ownable(msg.sender) {}

    function mintLiquidityLicense(address _recipient) public onlyOwner {
        _mint({to: _recipient, id: LIQUIDITY_LICENSE, value: 1, data: ""});
    }

    function mintTradingCredential(address _recipient) public onlyOwner {
        _mint({to: _recipient, id: KYC_CREDENTIAL, value: 1, data: ""});
    }
}
