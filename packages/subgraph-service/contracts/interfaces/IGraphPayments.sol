// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

interface IGraphPayments {
    enum ActionChoices {
        GoLeft,
        GoRight,
        GoStraight,
        SitStill
    }

    enum PaymentTypes {
        QueryFee,
        IndexingFee
    }

    function collect(
        address sender,
        address receiver,
        uint256 tokens,
        uint8 paymentType,
        uint256 tokensDataService
    ) external;
}