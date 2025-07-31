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
    use aztec::messages::logs::{
            //event::encode_and_encrypt_event,
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

    #[storage]
    struct Storage<Context> {
        received_amounts: Map<AztecAddress, PublicMutable<EmbeddedCurvePoint, Context>, Context>,
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

    #[private]
    fn transfer(
        recipient: AztecAddress, 
        amount: u128,
        account_nonce_is_zero: bool,
        viewing_key: Field, // get this from PXE somehow, aztec has a bunch of types of keys or what ever
        ) {
        //------ TODO read incoming balance sender ---------------
        //-------------------------------------------------------------


        // ---------- track amount spent ------------------------------
        let sender: AztecAddress = context.msg_sender();
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

        let new_OneWayNote: OneWayNote =  OneWayNote::new(viewing_key, prev_note.account_nonce + 1, prev_note.amount_spent + amount);
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
        let recipient_received_amounts_storage_slot: Field = storage.received_amounts.at(recipient).storage_slot;
        let current_recipient_amount_point: EmbeddedCurvePoint =  historical_public_storage_read(block_header,context.this_address(),recipient_received_amounts_storage_slot );//EmbeddedCurvePoint::generator(); //context.historical_header.public_storage_historical_read( recipient_received_amounts_storage_slot, context.this_address());
        let new_recipient_amount_point: EmbeddedCurvePoint = if (current_recipient_amount_point.x == 0) { // 0 = its recipients first incoming tx
            embedded_amount
        } else {
            embedded_curve_add(current_recipient_amount_point, embedded_amount)
        };
        AccountBasedPrivacy::at(context.this_address()).set_received_amount(recipient, new_recipient_amount_point).enqueue(&mut context);

        // TODO do public log instead and encrypt sender, amount, embedded_amount_nonce
        emit_event_in_private_log(
            Transfer { sender, recipient, amount, embedded_amount_nonce },
            &mut context,
            sender,
            recipient,
            PrivateLogContent.CONSTRAINED_ENCRYPTION,
        );
    }

    #[public]
    #[internal]
    fn set_received_amount(address: AztecAddress, amount: EmbeddedCurvePoint) {
        // TODO check msg_sender is the contract like in ethereum
        // #[internal] does the line below
        //assert(context.msg_sender() == context.this_address(), "only contract can call this function");
        storage.received_amounts.at(address).write(amount);
    }



    // the account
    // spentBalance
    // logs PXE wil do that
}
