// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "contracts/interfaces/IMain.sol";
import "contracts/interfaces/IBasketHandler.sol";
import "contracts/interfaces/IRToken.sol";
import "contracts/libraries/Fixed.sol";
import "contracts/p0/Rewardable.sol";

struct SlowIssuance {
    address issuer;
    uint256 amount; // {qRTok}
    Fix baskets; // {BU}
    address[] erc20s;
    uint256[] deposits; // {qTok}, same index as vault basket assets
    uint256 basketNonce;
    Fix blockAvailableAt; // {block.number} fractional
    bool processed;
}

/**
 * @title RTokenP0
 * @notice An ERC20 with an elastic supply and governable exchange rate to basket units.
 */
contract RTokenP0 is RewardableP0, ERC20Permit, IRToken {
    using EnumerableSet for EnumerableSet.AddressSet;
    using FixLib for Fix;
    using SafeERC20 for IERC20;

    // To enforce a fixed issuanceRate throughout the entire block
    mapping(uint256 => Fix) private blockIssuanceRates; // block.number => {qRTok/block}

    Fix public constant MIN_ISSUANCE_RATE = Fix.wrap(1e40); // {qRTok/block} 10k whole RTok

    // List of accounts. If issuances[user].length > 0 then (user is in accounts)
    EnumerableSet.AddressSet internal accounts;

    mapping(address => SlowIssuance[]) public issuances;

    Fix public basketsNeeded; //  {BU}

    Fix public issuanceRate; // {%} of RToken supply to issue per block

    // solhint-disable no-empty-blocks
    constructor(string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {}

    // solhint-enable no-empty-blocks

    function init(ConstructorArgs calldata args) internal override {
        issuanceRate = args.params.issuanceRate;
        emit IssuanceRateSet(FIX_ZERO, issuanceRate);
    }

    function setIssuanceRate(Fix val) external onlyOwner {
        emit IssuanceRateSet(issuanceRate, val);
        issuanceRate = val;
    }

    /// Begins the SlowIssuance accounting process, keeping a roughly constant basket rate
    /// @dev This function assumes that `deposits` are transferred here during this txn.
    /// @dev This function assumes that `baskets` will be due to issuer after slow issuance.
    /// @param issuer The account issuing the RToken
    /// @param amount {qRTok}
    /// @param baskets {BU}
    /// @param erc20s {address[]}
    /// @param deposits {qRTok[]}
    function issue(
        address issuer,
        uint256 amount,
        Fix baskets,
        address[] memory erc20s,
        uint256[] memory deposits
    ) external onlyComponent {
        assert(erc20s.length == deposits.length);

        // Calculate the issuance rate if this is the first issue in the block
        if (blockIssuanceRates[block.number].eq(FIX_ZERO)) {
            blockIssuanceRates[block.number] = fixMax(
                MIN_ISSUANCE_RATE,
                issuanceRate.mulu(totalSupply())
            );
        }

        (uint256 basketNonce, ) = main.basketHandler().lastSet();

        // Assumption: Main has already deposited the collateral
        SlowIssuance memory iss = SlowIssuance({
            issuer: issuer,
            amount: amount,
            baskets: baskets,
            erc20s: erc20s,
            deposits: deposits,
            basketNonce: basketNonce,
            blockAvailableAt: nextIssuanceBlockAvailable(amount, blockIssuanceRates[block.number]),
            processed: false
        });
        issuances[issuer].push(iss);

        accounts.add(issuer);
        emit IssuanceStarted(
            iss.issuer,
            issuances[issuer].length - 1,
            iss.amount,
            iss.baskets,
            iss.erc20s,
            iss.deposits,
            iss.blockAvailableAt
        );

        // Complete issuance instantly if it fits into this block
        if (iss.blockAvailableAt.lte(toFix(block.number))) {
            // At this point all checks have been done to ensure the issuance should vest
            assert(tryVestIssuance(issuer, issuances[issuer].length - 1) == iss.amount);
        }
    }

    /// Cancels a vesting slow issuance
    /// User Action
    /// If earliest == true, cancel id if id < endId
    /// If earliest == false, cancel id if endId <= id
    /// @param endId One end of the range of issuance IDs to cancel
    /// @param earliest If true, cancel earliest issuances; else, cancel latest issuances
    function cancel(uint256 endId, bool earliest) external returns (uint256[] memory deposits) {
        address account = _msgSender();

        SlowIssuance[] storage queue = issuances[account];
        (uint256 first, uint256 last) = earliest ? (0, endId) : (endId, queue.length);

        for (uint256 n = first; n < last; n++) {
            SlowIssuance storage iss = queue[n];
            if (!iss.processed) {
                deposits = new uint256[](iss.erc20s.length);
                for (uint256 i = 0; i < iss.erc20s.length; i++) {
                    IERC20(iss.erc20s[i]).safeTransfer(iss.issuer, iss.deposits[i]);
                    deposits[i] += iss.deposits[i];
                }
                iss.processed = true;
            }
        }
        emit IssuancesCanceled(account, first, last);
    }

    /// Completes all vested slow issuances for the account, callable by anyone
    /// @param account The address of the account to vest issuances for
    /// @return vested {qRTok} The total amount of RToken quanta vested
    function vest(address account, uint256 endId) external notPaused returns (uint256 vested) {
        require(main.basketHandler().status() == CollateralStatus.SOUND, "collateral default");

        main.poke();

        for (uint256 i = 0; i < endId; i++) vested += tryVestIssuance(account, i);
    }

    /// Return the highest index that could be completed by a vestIssuances call.
    function endIdForVest(address account) public view returns (uint256) {
        uint256 i;
        Fix currBlock = toFix(block.number);
        SlowIssuance[] storage queue = issuances[account];

        while (i < queue.length && queue[i].blockAvailableAt.lte(currBlock)) i++;
        return i;
    }

    /// Redeem a quantity of RToken from an account, keeping a roughly constant basket rate
    /// @param from The account redeeeming RToken
    /// @param amount {qRTok} The amount to be redeemed
    /// @param baskets {BU}
    function redeem(
        address from,
        uint256 amount,
        Fix baskets
    ) external onlyComponent {
        _burn(from, amount);

        emit BasketsNeededChanged(basketsNeeded, basketsNeeded.minus(baskets));
        basketsNeeded = basketsNeeded.minus(baskets);

        assert(basketsNeeded.gte(FIX_ZERO));
    }

    /// Mint a quantity of RToken to the `recipient`, decreasing the basket rate
    /// @param recipient The recipient of the newly minted RToken
    /// @param amount {qRTok} The amount to be minted
    function mint(address recipient, uint256 amount) external onlyComponent {
        _mint(recipient, amount);
    }

    /// Melt a quantity of RToken from the caller's account, increasing the basket rate
    /// @param amount {qRTok} The amount to be melted
    function melt(uint256 amount) external {
        _burn(_msgSender(), amount);
        emit Melted(amount);
    }

    /// An affordance of last resort for Main in order to ensure re-capitalization
    function setBasketsNeeded(Fix basketsNeeded_) external onlyComponent {
        emit BasketsNeededChanged(basketsNeeded, basketsNeeded_);
        basketsNeeded = basketsNeeded_;
    }

    function setMain(IMain main_) external onlyOwner {
        emit MainSet(main, main_);
        main = main_;
    }

    /// Tries to vest an issuance
    /// @return issued The total amount of RToken minted
    function tryVestIssuance(address issuer, uint256 index) internal returns (uint256 issued) {
        SlowIssuance storage iss = issuances[issuer][index];
        (uint256 basketNonce, ) = main.basketHandler().lastSet();
        if (
            !iss.processed &&
            iss.basketNonce == basketNonce &&
            iss.blockAvailableAt.lte(toFix(block.number))
        ) {
            for (uint256 i = 0; i < iss.erc20s.length; i++) {
                IERC20(iss.erc20s[i]).safeTransfer(address(main.backingManager()), iss.deposits[i]);
            }
            _mint(iss.issuer, iss.amount);
            issued = iss.amount;

            emit BasketsNeededChanged(basketsNeeded, basketsNeeded.plus(iss.baskets));
            basketsNeeded = basketsNeeded.plus(iss.baskets);

            iss.processed = true;
            emit IssuancesCompleted(issuer, index, index);
        }
    }

    /// Returns the block number at which an issuance for *amount* now can complete
    /// @param perBlock {qRTok/block} The uniform rate limit across the block
    function nextIssuanceBlockAvailable(uint256 amount, Fix perBlock) private view returns (Fix) {
        Fix before = toFix(block.number - 1);
        for (uint256 i = 0; i < accounts.length(); i++) {
            SlowIssuance[] storage queue = issuances[accounts.at(i)];
            if (queue.length > 0 && queue[queue.length - 1].blockAvailableAt.gt(before)) {
                before = queue[queue.length - 1].blockAvailableAt;
            }
        }
        return before.plus(divFix(amount, perBlock));
    }
}