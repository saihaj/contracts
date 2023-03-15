// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

contract L1GraphTokenLockMigratorMock {
    mapping(address => address) public migratedWalletAddress;

    function setMigratedAddress(address _l1Address, address _l2Address) external {
        migratedWalletAddress[_l1Address] = _l2Address;
    }

    function pullETH(address _l1Wallet, uint256 _amount) external {
        require(
            migratedWalletAddress[_l1Wallet] != address(0),
            "L1GraphTokenLockMigratorMock: unknown L1 wallet"
        );
        (bool success, ) = payable(msg.sender).call{ value: _amount }("");
        require(success, "L1GraphTokenLockMigratorMock: ETH pull failed");
    }
}