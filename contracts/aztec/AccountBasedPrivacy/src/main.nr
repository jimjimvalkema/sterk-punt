use dep::aztec::macros::aztec;
mod OneWayNote;

#[aztec]
pub contract AccountBasedPrivacy {
    use crate::OneWayNote::OneWayNote;
    use aztec::macros::{functions::{initializer, private, public, utility}, storage::storage};
    use aztec::prelude::{AztecAddress, Map, PrivateSet};
    use aztec::protocol_types::{
        abis::function_selector::FunctionSelector,
        traits::{FromField, ToField},
    };
    use std::embedded_curve_ops::{
        EmbeddedCurvePoint, EmbeddedCurveScalar, multi_scalar_mul, multi_scalar_mul_array_return,
    };

    #[storage]
    struct Storage<Context> {
        // make EmbeddedCurvePoint storage type
        received_amounts: Map<AztecAddress, EmbeddedCurvePoint, Context>,
        spent_amounts: PrivateSet<OneWayNote, Context>,
    }

    #[private]
    fn transfer(recipient: AztecAddress, amount: u128) {
        //TODO handle account nonce 0 case. if at zero we don't need prev_OneWayNote, if we can create OneWayNote(nonce=0) and we can push it's nullifier, everything is fine
        let sender = context.msg_sender();
        
        // get prev amount spent and note
        let storage_slot = storage.spent_amounts.storage_slot;
        //Safety: its fine
        let retrieved_prev_OneWayNote: RetrievedNote<OneWayNote> = unsafe { get_note_internal::<OneWayNote, 4>(storage_slot) }; 
        let prev_amount_spent = retrieved_prev_OneWayNote.note.amount_spent;
        let nullifier = retrieved_prev_OneWayNote.note.compute_nullifier();
        context.push_nullifier(nullifier);
        
        // can we spent this now?
        let prev_amount_received = get_amount_received(); // reads logs from PXE and asserts that received_amounts.at(sender) == pederson(totalAmountFromEncryptedLog)
        let new_amount_spent = amount + prev_amount_spent
        assert(amount_received >= new_amount_spent)


        // track what we spent
        let new_OneWayNote: OneWayNote = OneWayNote {
            retrieved_prev_OneWayNote.note.secret,
            retrieved_prev_OneWayNote.note.account_nonce + 1,
            new_amount_spent,
        };
        storage.commitments.insert(new_OneWayNote).emit(encode_and_encrypt_note(
            &mut context,
            from,
            to,
            amount,
        ));

        // give it to our recipient
        storage.received_amounts.at(recipient).add(amount_curve_point);

        // TODO amount_curve_point should be point=pedersen(amount, shared_secret)
        // and the curve point stored in received_balance is pedersen(amount1+amount2,etc, shared_secret1, shared_secret2)
        // which is the same as pedersen(total_amount, combined_shared_secret)
        // shared_secret is a key exchange based of public keys of recipient + sender
        // base_pt * alicePubKey * BobPrivKey = base_pt * alicePrivKey * BobPubkey
        // because:  base_pt * alicePrivKey * BobPubkey =  base_pt * alicePrivKey * base_pt* BobPrivKey
    }

    // the account
    // spentBalance
    // logs PXE wil do that
}
