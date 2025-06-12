use dep::aztec::macros::aztec;
mod OneWayNote;

#[aztec]
pub contract AccountBasedPrivacy {
    use crate::OneWayNote::OneWayNote;
    use aztec::macros::{functions::{initializer, private, public, utility}, storage::storage};
    use aztec::prelude::{AztecAddress, Map, PrivateSet, PrivateMutable, PublicMutable};
    use aztec::protocol_types::{
        abis::function_selector::FunctionSelector,
        traits::{FromField, ToField},
    };
    use aztec::messages::logs::{
            event::encode_and_encrypt_event,
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
        context::{PrivateCallInterface, PrivateContext},
        event::event_interface::EventInterface,
        history::public_storage::{PublicStorageHistoricalRead},};

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
    fn transfer(recipient: AztecAddress, amount: u128) {
        // //TODO handle account nonce 0 case. if at zero we don't need prev_OneWayNote, if we can create OneWayNote(nonce=0) and we can push it's nullifier, everything is fine
        let sender = context.msg_sender();
        
        // get prev amount spent and note
        let spent_amounts_storage_slot = storage.spent_amounts.storage_slot;
        // // Safety: its fine
        let retrieved_prev_OneWayNote: RetrievedNote<OneWayNote> = unsafe { get_note_internal::<OneWayNote, 3>(spent_amounts_storage_slot) }; 
        let prev_amount_spent = retrieved_prev_OneWayNote.note.amount_spent;
        // you can probably use something like destroy note unsafe or what ever.
        let prev_note_hash =  retrieved_prev_OneWayNote.note.compute_note_hash(spent_amounts_storage_slot);
        let nullifier = retrieved_prev_OneWayNote.note.compute_nullifier(&mut context, prev_note_hash);
        context.push_nullifier(nullifier);
        
        // // can we spent this now?
        let amount_received = 0x123; //get_amount_received(); // reads logs from PXE and asserts that received_amounts.at(sender) == pederson(totalAmountFromEncryptedLog)
        let new_amount_spent = amount + prev_amount_spent;
        assert(amount_received >= new_amount_spent);


        // // track what we spent
        let new_OneWayNote: OneWayNote = OneWayNote {
            secret: retrieved_prev_OneWayNote.note.secret,
            account_nonce: retrieved_prev_OneWayNote.note.account_nonce + 1,
            amount_spent: new_amount_spent,
        };

        storage.spent_amounts.insert(new_OneWayNote).emit(encode_and_encrypt_note(
            &mut context,
            sender,
            sender,
        ));


        // we could have used the shared secret of encode_and_encrypt_event but idk how, so lets just add an extra field with some randomness from the oracle (aka PXE)
        
        // Safety: it's in the senders best interest to indeed use real randomness, if not this tx amount is doxxed for the sender and recipient. But total balances aren't
        let embedded_amount_nonce = unsafe{ random() };
        // 
        let embedded_amount = pedersen_commitment([amount as Field, embedded_amount_nonce]);
        // needs to be constrained, since if its not. recipient will wont know their incoming balance which mean its bricked
        // TODO how does recipient find this event without trail decryption? Should we do a public event with a encrypted field instead?? Yes
        // Should we do something with finding the txs that enques to recipients address instead. No sucks too much work
        Transfer { sender, recipient, amount, embedded_amount_nonce }.emit(encode_and_encrypt_event(
            &mut context,
            recipient,
            sender
        ));

        // give it to our recipient
        let recipient_received_amounts_storage_slot = storage.received_amounts.at(recipient).storage_slot;

        // TODO how tf do i get the point instead of a Field value?? its a hash of somehting for sure. But what?
        // EmbeddedCurvePoint::generator(); is obviously not the way to do it ofc
        let block_header = context.get_block_header();
        let current_recipient_amount_point =  historical_public_storage_read(block_header,context.this_address(),recipient_received_amounts_storage_slot );//EmbeddedCurvePoint::generator(); //context.historical_header.public_storage_historical_read( recipient_received_amounts_storage_slot, context.this_address());
        let new_recipient_amount_point: EmbeddedCurvePoint = embedded_curve_add(current_recipient_amount_point, embedded_amount);
        // TODO why &mut ??
        AccountBasedPrivacy::at(context.this_address()).set_received_amount(recipient, new_recipient_amount_point).enqueue(&mut context);

    }

    #[public]
    fn set_received_amount(address: AztecAddress, amount: EmbeddedCurvePoint) {
        assert(context.msg_sender() == context.this_address(), "only contract can call this function");
        storage.received_amounts.at(address).write(amount);
    }



    // the account
    // spentBalance
    // logs PXE wil do that
}
