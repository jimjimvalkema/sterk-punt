use dep::aztec::macros::aztec;
mod OneWayNote;

#[aztec]
pub contract AccountBasedPrivacy {
    use crate::OneWayNote::OneWayNote;
    use aztec::macros::{functions::{initializer, private, public, utility, internal}, storage::storage};
    use aztec::prelude::{AztecAddress, Map, PrivateSet, PrivateMutable, PublicMutable};
    use aztec::protocol_types::{
        block_header::BlockHeader,
        abis::function_selector::FunctionSelector,
        traits::{FromField, ToField},
    };
    use aztec::event::event_interface::{emit_event_in_public_log};
    use aztec::protocol_types::{storage::map::derive_storage_slot_in_map};
    use aztec::messages::logs::{
            event::{to_encrypted_private_event_message},
            note::{encode_and_encrypt_note, encode_and_encrypt_note_unconstrained},
        };
    use aztec::note::{
            note_getter::{get_note_internal, get_notes},
            note_interface::NoteHash::{self, compute_note_hash, compute_nullifier},
            retrieved_note::RetrievedNote,};
    use std::embedded_curve_ops::{
        embedded_curve_add, EmbeddedCurvePoint, EmbeddedCurveScalar, multi_scalar_mul, multi_scalar_mul_array_return,fixed_base_scalar_mul
    };

    use std::hash::pedersen_commitment;

    use aztec::{
        event::event_interface::{emit_event_in_private_log, PrivateLogContent},
        context::{PrivateCallInterface, PrivateContext},
        event::event_interface::EventInterface,
        history::public_storage::{PublicStorageHistoricalRead},
        history::note_inclusion::ProveNoteInclusion};

    use aztec::keys::{ecdh_shared_secret::derive_ecdh_shared_secret_using_aztec_address, ephemeral::{generate_ephemeral_key_pair}};
    use aztec::utils::{point::get_sign_of_point,with_hash::WithHash::historical_public_storage_read};
    use aztec::oracle::{aes128_decrypt::aes128_decrypt_oracle, shared_secret::get_shared_secret};
    use dep::aztec::{
    macros::{
        events::event,
    },};

    use std::{meta::derive, ops::{Add, Sub}};
    use dep::aztec::protocol_types::traits::Serialize;
    use dep::aztec::oracle::random::random;
    use aztec::utils::with_hash::WithHash;

    #[storage]
    struct Storage<Context> {
        incoming_balances: Map<AztecAddress, PublicMutable<EmbeddedCurvePoint, Context>, Context>,
        spent_amounts: PrivateSet<OneWayNote, Context>,
    }

    #[derive(Serialize)]
    #[event]
    struct Transfer {
        sender: AztecAddress,
        recipient: AztecAddress,
        amount: u128,
        embedded_amount_nonce: Field
    }

    #[derive(Serialize)]
    #[event]
    struct PrivateIncomingTransfer {
        amount: u128,
        embedded_amount_nonce: Field
    }

    #[derive(Serialize)]
    #[event]
    struct PublicIncomingTransfer {
        recipient: AztecAddress, 
        encrypted_log: [Field;17], 
        log_randomness: Field
    }

    #[private]
    fn transfer(
            recipient: AztecAddress, 
            amount: u128,
            account_nonce_is_zero: bool,            // if true we make a note with 0 spent and nullify that, instead of retrieving one from PXE, remember it is nullified so you can only enable this bool once
            viewing_key: Field,                     // TODO get this from PXE somehow, aztec has a bunch of types of keys or what ever
            incoming_balance: u128,                 // can be outdated, it only goes up so its okay if outdated
            sum_embedded_amounts_nonces: Field,     // collect all incoming transfer logs, decrypt them, add the nonces together, thats this number
            incoming_balance_block_number: u32,     // at this block this in_coming_balance as an pedersen commitment existed onchain for this spenders address 
        ) {
        let sender: AztecAddress = context.msg_sender();
        //------ TODO read incoming balance sender ---------------
        // The problem is that there is no nice way to collect log within noir, 
        // so instead we do it in js and pass incoming_balance, nonce_sum, block_number
        //-------------------------------------------------------------

        let incoming_balances_slot: Field =  aztec::state_vars::storage::Storage::get_storage_slot(storage.incoming_balances);
        let incoming_balances_slot_at_sender = derive_storage_slot_in_map(incoming_balances_slot, sender);
        let contract_address: AztecAddress = context.this_address();
        let historical_incoming_balance_point: EmbeddedCurvePoint = WithHash::<EmbeddedCurvePoint, 3>::historical_public_storage_read(
            context.get_block_header_at(incoming_balance_block_number),
            contract_address,
            incoming_balances_slot_at_sender,
        );

        let reproduced_balance_point: EmbeddedCurvePoint = pedersen_commitment([incoming_balance as Field, sum_embedded_amounts_nonces]);
        assert(historical_incoming_balance_point == reproduced_balance_point, "reproduced_balance_point doesn't equal the incoming_balances retrieved from historic block");

        // ---------- track amount spent ------------------------------
        let block_header: BlockHeader = context.get_block_header();
        // TODO make function of this
        let spent_amounts_storage_slot: Field = storage.spent_amounts.storage_slot;
        let (prev_note, prev_note_hash): (OneWayNote, Field) = if account_nonce_is_zero {
            let prev_note: OneWayNote = OneWayNote::new(viewing_key, 0, 0);
            let prev_note_hash: Field = prev_note.compute_note_hash(spent_amounts_storage_slot);
            // cant check inclusion, we are at 0, we got to start somewhere! 
            // We never have to put this note_hash onchain, we will do that for nonce 1
            // if this note is note nullified yet, it means this is our first spend tx!
            (prev_note, prev_note_hash)
        } else {
            // Safety: its fine
            let retrieved_prev_OneWayNote: RetrievedNote<OneWayNote> = unsafe { get_note_internal::<OneWayNote, 3>(spent_amounts_storage_slot) }; 
            let prev_note: OneWayNote = retrieved_prev_OneWayNote.note;
            let prev_note_hash: Field = prev_note.compute_note_hash(spent_amounts_storage_slot);
            // prove note hash inclusion 
            block_header.prove_note_inclusion(retrieved_prev_OneWayNote, spent_amounts_storage_slot);
            (prev_note, prev_note_hash)
        };
        let nullifier: Field = prev_note.compute_nullifier(&mut context, prev_note_hash);
        context.push_nullifier(nullifier);

        let new_OneWayNote: OneWayNote = OneWayNote::new(viewing_key, prev_note.account_nonce + 1, prev_note.amount_spent + amount);
        storage.spent_amounts.insert(new_OneWayNote).emit(encode_and_encrypt_note(
            &mut context,
            sender,
            sender,
        ));
        //-------------------------------------------------------------
        _increase_balance(context.inputs, sender,recipient,amount,block_header);
        //-------------------------------------------------------------
    }

    // pretty sure this is inefficient, should not use  #[private] or #[internal] even
    #[private]
    #[internal]
    fn _increase_balance(
            sender: AztecAddress, 
            recipient: AztecAddress,
            amount: u128, 
            block_header: BlockHeader
        ) {
        // ------ track recipient incoming balance ---------------
        // we could have used the shared secret of encode_and_encrypt_event but idk how, so lets just add an extra field with some randomness from the oracle (aka PXE)
        // Safety: it's in the senders best interest to indeed use real randomness, if not this tx amount is doxxed for the sender and recipient. But total balances aren't
        let embedded_amount_nonce: Field = unsafe{ random() };
        // 
        let embedded_amount: EmbeddedCurvePoint = pedersen_commitment([amount as Field, embedded_amount_nonce]);
        // needs to be constrained, since if its not. recipient wont know their incoming balance which mean its bricked
        // TODO how does recipient find this event without trail decryption? Should we do a public event with a encrypted field instead?? Yes!
        // Should we do something with finding the txs that enqueus to recipients address instead. No sucks too much work

        // update recipients incoming balance
        let recipient_incoming_balances_storage_slot: Field = storage.incoming_balances.at(recipient).storage_slot;
        let current_recipient_amount_point: EmbeddedCurvePoint =  historical_public_storage_read(block_header,context.this_address(),recipient_incoming_balances_storage_slot );//EmbeddedCurvePoint::generator(); //context.historical_header.public_storage_historical_read( recipient_incoming_balances_storage_slot, context.this_address());
        let new_recipient_amount_point: EmbeddedCurvePoint = if (current_recipient_amount_point.x == 0) { // 0 = its recipients first incoming tx
            embedded_amount
        } else {
            embedded_curve_add(current_recipient_amount_point, embedded_amount)
        };
        let incoming_transfer_event: PrivateIncomingTransfer = PrivateIncomingTransfer { amount, embedded_amount_nonce };
        // TODO double check this is constrained, if not attacker can brick any address they see
        let (encrypted_log, log_randomness): ([Field; 17], Field) = to_encrypted_private_event_message(incoming_transfer_event, recipient);

        AccountBasedPrivacy::at(context.this_address()).set_received_amount(recipient, new_recipient_amount_point, encrypted_log, log_randomness).enqueue(&mut context);

        // just for accounting for sender
        emit_event_in_private_log(
            Transfer { sender, recipient, amount, embedded_amount_nonce },
            &mut context,
            sender,
            sender,
            PrivateLogContent.NO_CONSTRAINTS,
        );
    }

    #[public]
    #[internal]
    fn set_received_amount(address: AztecAddress, amount: EmbeddedCurvePoint, encrypted_log: [Field;17], log_randomness: Field) {
        emit_event_in_public_log(
            PublicIncomingTransfer { recipient: address, encrypted_log, log_randomness},
            &mut context,
        );
        storage.incoming_balances.at(address).write(amount);
    }



    // the account
    // spentBalance
    // logs PXE wil do that
}
