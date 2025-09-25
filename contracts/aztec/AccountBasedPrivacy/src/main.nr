mod accountBasedNote;

use dep::aztec::{macros::aztec};

#[aztec]
pub contract AccountBasedPrivacy {
    use aztec::{
        context,
        event::event_interface::{emit_event_in_private, MessageDelivery},
        oracle::random::random,
        event::event_interface::{emit_event_in_public},
        macros::{events::event, functions::{internal, private, public, utility}, storage::storage},
        note::{note_getter::get_note},
        state_vars::{Map, PublicMutable, storage::HasStorageSlot, private_mutable::PrivateMutable},
        protocol_types::{
            abis::block_header::BlockHeader,
            address::AztecAddress,
            storage::map::derive_storage_slot_in_map,
            traits::Serialize,
        },
        utils::{
            with_hash::WithHash::{self},
        },
    };
    use crate::{
        accountBasedNote::AccountBasedNote,
    };
    use std::{
        embedded_curve_ops::{embedded_curve_add, EmbeddedCurvePoint},
        hash::pedersen_commitment,
        ops::Add
    };

    #[storage]
    pub struct Storage<Context> {
        pub received_amounts: Map<AztecAddress, PublicMutable<WithHash<EmbeddedCurvePoint, 3>, Context>, Context>,
        pub spent_amounts: PrivateMutable<AccountBasedNote, Context>, // actually make sure only AztecAddress own the AccountBasedNote
    }

    #[derive(Serialize)]
    #[event]
    pub struct PrivateIncomingTransfer {
        pub amount: u128,
        pub amount_blinding_nonce: Field,
    }

    #[derive(Serialize)]
    #[event]
    pub struct PublicIncomingTransfer {
        recipient: AztecAddress,
    }

    #[utility]
    unconstrained fn get_received_amount(address: AztecAddress) -> EmbeddedCurvePoint {
        let point: WithHash<EmbeddedCurvePoint, 3> = storage.received_amounts.at(address).read();
        point.get_value()
    }

    #[private]
    fn mint(recipient: AztecAddress, amount: u128) {
        let contract_address: AztecAddress = context.this_address();
        increase_balance(
            context.inputs,
            recipient,
            amount,
            contract_address,
        );
    }

    #[private]
    fn transfer(
        recipient: AztecAddress,
        amount: u128,
        account_nonce_is_zero: bool,                // if true we make a note with 0 spent and nullify that, instead of retrieving one from PXE, remember it is nullified so you can only enable this bool once
        viewing_key: Field,                         // TODO get this from PXE somehow, aztec has a bunch of types of keys or what ever
        received_amount: u128,                      // can be outdated, it only goes up so its okay if outdated
        blinding_nonce_point: EmbeddedCurvePoint,   // collect all received transfer logs, decrypt them, add the nonces together, then create a point that is pedersen([0,sum_nonce % GrumpkinScalar.MODULUS])
        received_amount_block_number: u32,          // at this block this in_coming_balance as an pedersen commitment existed onchain for this spenders address
    ) {
        assert(received_amount != 0, "received_amount cant be zero"); // make debugging easier

        // context variables
        let sender: AztecAddress = context.msg_sender();
        let contract_address: AztecAddress = context.this_address();
        let block_header: BlockHeader = context.get_block_header_at(received_amount_block_number);

        // verify inclusion provided received balance
        // TODO handle overflows of received_amount. external party can grief their account? since overflowing will cause amount to be = (a + b) % n (n group order).
        let received_amount_point: EmbeddedCurvePoint =
            pedersen_commitment([received_amount as Field, 0]);
        let received_amount_point_blinded_point: EmbeddedCurvePoint =
            blinding_nonce_point.add(received_amount_point);
        check_inclusion_received_amount(
            context.inputs,
            sender,
            received_amount_point_blinded_point,
            contract_address,
            block_header,
        );

        // get previous spent note
        let prev_note = if (account_nonce_is_zero) {
            AccountBasedNote::new(viewing_key, 0,0)
        } else {
            // afaik this does proof inclusion
            // we don't use storage.spent_amounts.get_note() because that nullifies it, we are already going to do that below so no need
            let (retrieved_note, note_hash_for_read_request) = get_note(&mut context, storage.spent_amounts.get_storage_slot());
            retrieved_note.note
        };


        // create next note spent
        let new_note: AccountBasedNote = AccountBasedNote::new(
            viewing_key,
            prev_note.account_nonce + 1,
            prev_note.amount_spent + amount,
        );
        storage.spent_amounts.replace(new_note); //TODO emit it //.emit(&mut context, recipient, MessageDelivery.CONSTRAINED_ONCHAIN);



        // now check they have enough ofc
        let total_spent_after_tx: u128 = amount + prev_note.amount_spent;
        assert(
            received_amount >= total_spent_after_tx,
            "total_spent_after_tx is larger then historic received_amount",
        );

        // homomorphically add the amount to the recipients received balance
        // and emit a event so recipient can reproduce their received balance
        increase_balance(context.inputs, recipient, amount, contract_address);
    }

    #[public]
    #[internal]
    fn add_to_received_amount_amount(
        recipient: AztecAddress,
        added_amount_point: EmbeddedCurvePoint,
    ) {
        emit_event_in_public(PublicIncomingTransfer { recipient }, &mut context);
        let current_point: EmbeddedCurvePoint =
            storage.received_amounts.at(recipient).read().get_value();

        let new_point: EmbeddedCurvePoint = if (current_point.x == 0) {
            added_amount_point
        } else {
            embedded_curve_add(current_point, added_amount_point)
        };
        let new_point_with_hash = WithHash::new(new_point);
        storage.received_amounts.at(recipient).write(new_point_with_hash);
    }

    #[private]
    #[internal]
    fn check_inclusion_received_amount(
        sender: AztecAddress,
        received_amount_point: EmbeddedCurvePoint,
        contract_address: AztecAddress,
        block_header: BlockHeader,
    ) {
        let received_amounts_slot: Field = storage.received_amounts.get_storage_slot();
        let received_amounts_slot_at_sender = derive_storage_slot_in_map(received_amounts_slot, sender);
        let historical_received_amount_point: EmbeddedCurvePoint = WithHash::<EmbeddedCurvePoint, 3>::historical_public_storage_read(
            block_header,
            contract_address,
            received_amounts_slot_at_sender,
        );
        assert_eq(
            historical_received_amount_point,
            received_amount_point,
            "retrieved historical_received_amount_point doesn't match provided received_amount_point",
        );
    }
    
    #[private]
    //#[internal] 
    //@TODO bug cant be internal i get error `Function increase_balance can only be called internally 'context.msg_sender() == context.this_address()'`
    // is the enqueue messing with things?
    fn increase_balance(
        recipient: AztecAddress,
        amount: u128,
        contract_address: AztecAddress
    ) {
        // ------ track recipient received balance ---------------
        // we could have used the shared secret of encode_and_encrypt_event but idk how, so lets just add an extra field with some randomness from the oracle (aka PXE)
        // Safety: it's in the senders best interest to indeed use real randomness, if not this tx amount is dox'ed for the sender and recipient. But total balances aren't
        let amount_blinding_nonce: Field = unsafe { random() };
        let amount_point: EmbeddedCurvePoint = pedersen_commitment([amount as Field, amount_blinding_nonce]);

        let received_transfer_event = PrivateIncomingTransfer { amount, amount_blinding_nonce };
        emit_event_in_private(
            received_transfer_event,
            &mut context,
            recipient,
            MessageDelivery.CONSTRAINED_ONCHAIN, // needs to be constrained, if not recipients account can be bricked by an attacker
        );

        AccountBasedPrivacy::at(contract_address)
            .add_to_received_amount_amount(recipient, amount_point)
            .enqueue(&mut context);
    }
}
