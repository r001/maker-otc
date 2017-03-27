pragma solidity ^0.4.8;

import "erc20/erc20.sol";

contract EventfulMarket {
    event ItemUpdate( uint id );
    event Trade( uint sell_how_much, address indexed sell_which_token,
                 uint buy_how_much, address indexed buy_which_token );

    event LogMake(
        bytes32  indexed  id,
        bytes32  indexed  pair,
        address  indexed  maker,
        ERC20             haveToken,
        ERC20             wantToken,
        uint128           haveAmount,
        uint128           wantAmount,
        uint64            timestamp
    );

    event LogTake(
        bytes32           id,
        bytes32  indexed  pair,
        address  indexed  maker,
        ERC20             haveToken,
        ERC20             wantToken,
        address  indexed  taker,
        uint128           takeAmount,
        uint128           giveAmount,
        uint64            timestamp
    );

    event LogKill(
        bytes32  indexed  id,
        bytes32  indexed  pair,
        address  indexed  maker,
        ERC20             haveToken,
        ERC20             wantToken,
        uint128           haveAmount,
        uint128           wantAmount,
        uint64            timestamp
    );
}

contract SimpleMarket is EventfulMarket {
    bool locked;
    address contractOwner;
    bool closed;
    uint cancel_mingas=10000;


    function SimpleMarket(){
        contractOwner = msg.sender;
    }

    function destructContract() returns (bool){
        assert(contractOwner == msg.sender);
        assert(offer_count == 0);
        selfdestruct(contractOwner);
    }

    function setCancelMingas(uint mingas) returns (bool){
        assert(contractOwner == msg.sender);
        cancel_mingas=mingas;
        return true;
    }

    function cancelAllOffers() returns (bool) {
        assert(closed);
        assert(contractOwner == msg.sender);
        for(uint id = first_offer_id; id != 0; id = next_offer_id[id]){
            cancel(id);
            if( msg.gas < cancel_mingas ) { return false; }
        }
        return true;
    }

    function isClosed() constant returns (bool) {
        return (closed);
    }
    
    function setClosed(bool closeMarket) returns (bool) {
        assert(contractOwner == msg.sender);
        closed = closeMarket;
        return true;
    }

    modifier synchronized {
        assert(!locked);
        locked = true;
        _;
        locked = false;
    }

    function assert(bool x) internal {
        if (!x) throw;
    }

    struct OfferInfo {
        uint     sell_how_much;
        ERC20    sell_which_token;
        uint     buy_how_much;
        ERC20    buy_which_token;
        address  owner;
        bool     active;
    }

    mapping (uint => OfferInfo) public offers;

    mapping( uint => uint ) public prev_offer_id;
    
    mapping( uint => uint ) public next_offer_id;

    uint public first_offer_id;

    uint public last_offer_id;

    uint offer_count;

    mapping( address => uint) public min_sell_amount;

    function next_id() internal returns (uint) {
        offer_count++;
        last_offer_id++; 
        return last_offer_id;
    }

    // after market lifetime has elapsed, no new offers are allowed
    modifier can_offer {
        assert(!isClosed());
        _;
    }
    // after close, no new buys are allowed
    modifier can_buy(uint id) {
        assert(isActive(id));
        assert(!isClosed());
        _;
    }
    // after close, anyone can cancel an offer
    modifier can_cancel(uint id) {
        assert(isActive(id));
        assert(isClosed() || (msg.sender == getOwner(id)));
        _;
    }
    function isActive(uint id) constant returns (bool active) {
        return offers[id].active;
    }
    function getOwner(uint id) constant returns (address owner) {
        return offers[id].owner;
    }
    function getOffer( uint id ) constant returns (uint, ERC20, uint, ERC20) {
      var offer = offers[id];
      return (offer.sell_how_much, offer.sell_which_token,
              offer.buy_how_much, offer.buy_which_token);
    }

    function getLastOffer() constant returns(uint) {
        return last_offer_id;
    }

    function getFirstOffer() constant returns(uint) {
        return first_offer_id;
    }

    function getPrevOfferId(uint id) constant returns(uint) {
        return prev_offer_id[id];
    }

    function getNextOfferId(uint id) constant returns(uint) {
        return next_offer_id[id];
    }

    function getOfferCount() constant returns(uint) {
        return offer_count;
    }

    function setMinSellAmount(ERC20 sell_which_token, uint min_amount) 
    returns (bool success) {
        assert(contractOwner == msg.sender);
        min_sell_amount[sell_which_token] = min_amount;
        success = true;
    }
    
    function getMinSellAmount(ERC20 sell_which_token) 
    constant
    returns (uint) {
        return min_sell_amount[sell_which_token];
    }

    function deleteMinSellAmount(ERC20 sell_which_token) 
    returns (bool success) {
        assert(contractOwner == msg.sender);
        delete min_sell_amount[sell_which_token];
        success = true;
    }

    // non underflowing subtraction
    function safeSub(uint a, uint b) internal returns (uint) {
        assert(b <= a);
        return a - b;
    }
    // non overflowing multiplication
    function safeMul(uint a, uint b) internal returns (uint c) {
        c = a * b;
        assert(a == 0 || c / a == b);
    }

    function trade( address seller, uint sell_how_much, ERC20 sell_which_token,
                    address buyer,  uint buy_how_much,  ERC20 buy_which_token )
        internal
    {
        var seller_paid_out = buy_which_token.transferFrom( buyer, seller, buy_how_much );
        assert(seller_paid_out);
        var buyer_paid_out = sell_which_token.transfer( buyer, sell_how_much );
        assert(buyer_paid_out);
        Trade( sell_how_much, sell_which_token, buy_how_much, buy_which_token );
    }

    // ---- Public entrypoints ---- //

    function make(
        ERC20    haveToken,
        ERC20    wantToken,
        uint128  haveAmount,
        uint128  wantAmount
    ) returns (bytes32 id) {
        return bytes32(offer(haveAmount, haveToken, wantAmount, wantToken));
    }

    function take(bytes32 id, uint128 maxTakeAmount) {
        assert(buy(uint256(id), maxTakeAmount));
    }

    function kill(bytes32 id) {
        assert(cancel(uint256(id)));
    }

    // Make a new offer. Takes funds from the caller into market escrow.
    function offer( uint sell_how_much, ERC20 sell_which_token
                  , uint buy_how_much,  ERC20 buy_which_token )
        can_offer
        synchronized
        returns (uint id)
    {
        assert(min_sell_amount[sell_which_token] <= sell_how_much);
        assert(uint128(sell_how_much) == sell_how_much);
        assert(uint128(buy_how_much) == buy_how_much);
        assert(sell_how_much > 0);
        assert(sell_which_token != ERC20(0x0));
        assert(buy_how_much > 0);
        assert(buy_which_token != ERC20(0x0));
        assert(sell_which_token != buy_which_token);

        OfferInfo memory info;
        info.sell_how_much = sell_how_much;
        info.sell_which_token = sell_which_token;
        info.buy_how_much = buy_how_much;
        info.buy_which_token = buy_which_token;
        info.owner = msg.sender;
        info.active = true;
        id = next_id();
        offers[id] = info;

        if ( offer_count >= 2 ) {
            //offers[id] is at least the second offer that was stored

            prev_offer_id[id] = last_offer_id;
            next_offer_id[last_offer_id] = id;
        } else {
            //offers[id] is the first offer that is stored

            first_offer_id = id;
        }
        last_offer_id = id;

        var seller_paid = sell_which_token.transferFrom( msg.sender, this, sell_how_much );
        assert(seller_paid);

        ItemUpdate(id);
        LogMake(
            bytes32(id),
            sha3(sell_which_token, buy_which_token),
            msg.sender,
            sell_which_token,
            buy_which_token,
            uint128(sell_how_much),
            uint128(buy_how_much),
            uint64(now)
        );
    }

    // Accept given `quantity` of an offer. Transfers funds from caller to
    // offer maker, and from market to caller.
    function buy( uint id, uint quantity )
        can_buy(id)
        synchronized
        returns ( bool success )
    {
        assert(uint128(quantity) == quantity);

        // read-only offer. Modify an offer by directly accessing offers[id]
        OfferInfo memory offer = offers[id];

        // inferred quantity that the buyer wishes to spend
        uint spend = safeMul(quantity, offer.buy_how_much) / offer.sell_how_much;
        assert(uint128(spend) == spend);

        if ( spend > offer.buy_how_much || quantity > offer.sell_how_much ) {
            // buyer wants more than is available
            success = false;
        } else if ( spend == offer.buy_how_much && quantity == offer.sell_how_much ) {
            // buyer wants exactly what is available
            delete offers[id];

            trade( offer.owner, quantity, offer.sell_which_token,
                   msg.sender, spend, offer.buy_which_token );

            ItemUpdate(id);
            LogTake(
                bytes32(id),
                sha3(offer.sell_which_token, offer.buy_which_token),
                offer.owner,
                offer.sell_which_token,
                offer.buy_which_token,
                msg.sender,
                uint128(offer.sell_how_much),
                uint128(offer.buy_how_much),
                uint64(now)
            );

            success = true;
        } else if ( spend > 0 && quantity > 0 ) {
            // buyer wants a fraction of what is available
            offers[id].sell_how_much = safeSub(offer.sell_how_much, quantity);
            offers[id].buy_how_much = safeSub(offer.buy_how_much, spend);

            trade( offer.owner, quantity, offer.sell_which_token,
                    msg.sender, spend, offer.buy_which_token );

            ItemUpdate(id);
            LogTake(
                bytes32(id),
                sha3(offer.sell_which_token, offer.buy_which_token),
                offer.owner,
                offer.sell_which_token,
                offer.buy_which_token,
                msg.sender,
                uint128(quantity),
                uint128(spend),
                uint64(now)
            );

            success = true;
        } else {
            // buyer wants an unsatisfiable amount (less than 1 integer)
            success = false;
        }
    }

    // Cancel an offer. Refunds offer maker.
    function cancel( uint id )
        can_cancel(id)
        synchronized
        returns ( bool success )
    {
        // read-only offer. Modify an offer by directly accessing offers[id]
        OfferInfo memory offer = offers[id];

        if(last_offer_id == id){
            //offers[id] is the last offer in the sorted list
        
            last_offer_id = prev_offer_id[id]; 
            delete next_offer_id[prev_offer_id[id]];
            delete prev_offer_id[id];
            if ( offer_count == 1 ) {
                //offer was the last offer 
        
                first_offer_id = 0;
            }
        } else if( first_offer_id == id ) {
            //offers[id] is the first offer
        
            first_offer_id = next_offer_id[id]; 
            delete prev_offer_id[ next_offer_id[id] ];
            delete next_offer_id[id];
        } else {
            //offers[id] is between the last and the first offer

            prev_offer_id[next_offer_id[id]] = prev_offer_id[id];
            next_offer_id[prev_offer_id[id]] = next_offer_id[id];
            delete prev_offer_id[id];
            delete next_offer_id[id];
        }

        offer_count--;
        delete offers[id];

        var seller_refunded = offer.sell_which_token.transfer( offer.owner , offer.sell_how_much );
        assert(seller_refunded);

        ItemUpdate(id);
        LogKill(
            bytes32(id),
            sha3(offer.sell_which_token, offer.buy_which_token),
            offer.owner,
            offer.sell_which_token,
            offer.buy_which_token,
            uint128(offer.sell_how_much),
            uint128(offer.buy_how_much),
            uint64(now)
        );

        success = true;
    }
}
