mod accountBasedNote;
use crate::accountBasedNote::AccountBasedNote;

use dep::aztec::{
    macros::aztec,
    context::PrivateContext,
    event::event_interface::{emit_event_in_private_log, PrivateLogContent},
    history::note_inclusion::ProveNoteInclusion,
    history::public_storage::PublicStorageHistoricalRead,
    note::{
        note_getter::get_note_internal,
        note_interface::NoteHash,
        retrieved_note::RetrievedNote,
    },
    oracle::random::random,
    prelude::AztecAddress,
    protocol_types::{
        hash::poseidon2_hash,
        poseidon2, block_header::BlockHeader,
        storage::map::derive_storage_slot_in_map,
        traits::{Serialize, Deserialize, Packable},
    },
    state_vars::storage::Storage::get_storage_slot,
    utils::{
        with_hash::{oracle},
        with_hash::WithHash,
    },
};
use dep::aztec::oracle::debug_log::{ debug_log_format };


use std::{
    embedded_curve_ops::{EmbeddedCurvePoint},
    hash::pedersen_commitment,
};


// pub struct SerializableCurvePoint {
//     pub inner: EmbeddedCurvePoint
// }

// impl Serialize<3> for SerializableCurvePoint {
//     fn serialize(self: Self) -> [Field; 3] {
//         [self.inner.x, self.inner.y, self.inner.is_infinite as Field]
//     }
// }

// impl Deserialize<3> for SerializableCurvePoint {
//     fn deserialize(serialized: [Field; 3]) -> Self {
//         SerializableCurvePoint {
//             inner: EmbeddedCurvePoint { 
//                 x: serialized[0], 
//                 y: serialized[1], 
//                 is_infinite: serialized[2] != 0,
//             }
//         }
//     }
// }

// // Packable implementation
// impl Packable<3> for SerializableCurvePoint {
//     fn pack(self: Self) -> [Field; 3] {
//         self.serialize()
//     }

//     fn unpack(packed: [Field; 3]) -> Self {
//         Self::deserialize(packed)
//     }
// }

// impl Eq for SerializableCurvePoint {
//     fn eq(self: Self, other: Self) -> bool {
//         self.inner.eq(other.inner)
//     }
// }




fn _check_inclusion_received_amount(
    sender: AztecAddress,
    received_amount_point: EmbeddedCurvePoint,

    contract_address: AztecAddress,
    block_number: u32,
    block_header: BlockHeader,
    storage: AccountBasedPrivacy::Storage<&mut PrivateContext>,
) {
    let received_amounts_slot: Field = get_storage_slot(storage.received_amounts);
    let received_amounts_slot_at_sender = derive_storage_slot_in_map(received_amounts_slot, sender);

    // // ---- This is debug, cam be removed for efficiency --------------
    // let value_hash: Field = block_header.public_storage_historical_read(
    //     received_amounts_slot_at_sender,
    //     contract_address
    // );
    // assert(value_hash != 0, "cant read a balance that is not initialize yet! received_amount is likely incorrect or received_amount_block_number is before this account received it's first transaction.");

    // //-----------useless check, its unconstrained debug only --- 
    // let historical_received_amount_point_storage_read = unsafe {
    //     oracle::storage::storage_read::<EmbeddedCurvePoint, 3>(contract_address, received_amounts_slot_at_sender, block_number)
    // };
    // assert(historical_received_amount_point_storage_read == received_amount_point, "received_amount_point doesn't match point from oracle::storage::storage_read");
    // // ----------------------------------------------------
    
    // this breaks but it shouldn't
    let historical_received_amount_point: EmbeddedCurvePoint = WithHash::<EmbeddedCurvePoint, 3>::historical_public_storage_read(
        block_header,
        contract_address,
        received_amounts_slot_at_sender,
    );
    assert(historical_received_amount_point == received_amount_point, "received_amount_point is not in the historical public storage at that specific block number");
}


fn _retrieve_prev_account_based_note(
    account_nonce_is_zero: bool,
    viewing_key: Field,

    block_header: BlockHeader,
    storage: AccountBasedPrivacy::Storage<&mut PrivateContext>,
) -> (AccountBasedNote, Field) {
    let spent_amounts_storage_slot: Field = storage.spent_amounts.storage_slot;

    let (prev_note, prev_note_hash) = if account_nonce_is_zero {
        let prev_note: AccountBasedNote = AccountBasedNote::new(viewing_key, 0, 0);
        let prev_note_hash: Field = prev_note.compute_note_hash(spent_amounts_storage_slot);
        // cant check inclusion, we are at 0, we got to start somewhere!
        // We never have to put this note_hash onchain, we will do that for nonce 1
        // if this note is note nullified yet, it means this is our first spend tx!
        (prev_note, prev_note_hash)
    } else {
        // Safety: its fine
        let retrieved_prev_AccountBasedNote: RetrievedNote<AccountBasedNote> =
            unsafe { get_note_internal::<AccountBasedNote, 3>(spent_amounts_storage_slot) };
        let prev_note: AccountBasedNote = retrieved_prev_AccountBasedNote.note;
        let prev_note_hash: Field = prev_note.compute_note_hash(spent_amounts_storage_slot);
        // prove note hash inclusion
        // TODO find out if we can use the logic to spend pending notes.
        block_header.prove_note_inclusion(retrieved_prev_AccountBasedNote, spent_amounts_storage_slot);
        (prev_note, prev_note_hash)
    };

    (prev_note, prev_note_hash)
}

fn increase_balance(
    sender: AztecAddress,
    recipient: AztecAddress,
    amount: u128,

    contract_address: AztecAddress,
    context: &mut PrivateContext,
) {
    // ------ track recipient received balance ---------------
    // we could have used the shared secret of encode_and_encrypt_event but idk how, so lets just add an extra field with some randomness from the oracle (aka PXE)
    // Safety: it's in the senders best interest to indeed use real randomness, if not this tx amount is dox'ed for the sender and recipient. But total balances aren't
    let amount_blinding_nonce: Field = unsafe { random() };
    let amount_point: EmbeddedCurvePoint = pedersen_commitment([amount as Field, amount_blinding_nonce]);

    let received_transfer_event = AccountBasedPrivacy::PrivateIncomingTransfer { amount, amount_blinding_nonce };
       emit_event_in_private_log(
        received_transfer_event,
        context,
        sender,
        recipient,
        PrivateLogContent.CONSTRAINED_ENCRYPTION, // needs to be constrained, if not recipients account can be bricked by an attacker
    );
    // TODO double check this is constrained, if not attacker can brick any address they see
    //let (encrypted_log, log_randomness) = to_encrypted_private_event_message(received_transfer_event, recipient);

    AccountBasedPrivacy::at(contract_address).add_to_received_amount_amount(
        recipient,
        amount_point ,
    ).enqueue(context);
}

#[aztec]
pub contract AccountBasedPrivacy {
    use aztec::{
        event::event_interface::emit_event_in_public_log,
        macros::{
            events::event,
            functions::{internal, private, public, utility},
            storage::storage,
        },
        messages::logs::note::encode_and_encrypt_note,
        note::{
            note_interface::NoteHash,
        },
        prelude::{AztecAddress, Map, PrivateSet, PublicMutable},
        protocol_types::{
            block_header::BlockHeader,
            traits::Serialize,
        },
    };
    use crate::{
        accountBasedNote::AccountBasedNote,
        _check_inclusion_received_amount,
        _retrieve_prev_account_based_note,
        increase_balance,
        // SerializableCurvePoint,
    };
    use std::{
        embedded_curve_ops::{
            embedded_curve_add,
            EmbeddedCurvePoint,
        },
        hash::pedersen_commitment,
    };
    use std::ops::Add;

    #[storage]
    pub struct Storage<Context> {
        pub received_amounts: Map<AztecAddress, PublicMutable<EmbeddedCurvePoint, Context>, Context>,
        pub spent_amounts: PrivateSet<AccountBasedNote, Context>,
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
        let point = storage.received_amounts.at(address).read();
        point
    }

    #[private]
    fn mint(
        recipient: AztecAddress,
        amount: u128,
    ) {
        let contract_address: AztecAddress = context.this_address();
        increase_balance(
            context.msg_sender(),
            recipient,
            amount,
            contract_address,
            &mut context,
        );
    }

    #[private]
    fn transfer(
        recipient: AztecAddress,
        amount: u128,
        account_nonce_is_zero: bool,                // if true we make a note with 0 spent and nullify that, instead of retrieving one from PXE, remember it is nullified so you can only enable this bool once
        viewing_key: Field,                         // TODO get this from PXE somehow, aztec has a bunch of types of keys or what ever
        received_amount: u128,                      // can be outdated, it only goes up so its okay if outdated
        blinding_nonce_point: EmbeddedCurvePoint,   // collect all received transfer logs, decrypt them, add the nonces together, then create a point that is pedersen([0,sum_nonce]), but because of the field limit you need to do:
                                                    // blinding_nonce_point = pedersen([0,field_limit]) * sum_nonce / field_limit +  pedersen([0,sum_nonce % field_limit])
        received_amount_block_number: u32,          // at this block this in_coming_balance as an pedersen commitment existed onchain for this spenders address 
    ) {
        assert(received_amount != 0, "received_amount cant be zero"); // make debugging easier

        // context variables
        let sender: AztecAddress = context.msg_sender();
        let contract_address: AztecAddress = context.this_address();
        let block_header: BlockHeader = context.get_block_header_at(received_amount_block_number);

        // verify inclusion provided received balance
        let received_amount_point: EmbeddedCurvePoint = pedersen_commitment([received_amount as Field, 0]);
        let received_amount_point_blinded_point: EmbeddedCurvePoint = blinding_nonce_point.add(received_amount_point);
        _check_inclusion_received_amount(
            sender,
            received_amount_point_blinded_point,
            contract_address,
            received_amount_block_number,
            block_header,
            storage,
        );

        // get previous spent note
        let (prev_note, prev_note_hash) = _retrieve_prev_account_based_note(
            account_nonce_is_zero, 
            viewing_key, 
            
            block_header, 
            storage
        );

        //nullify it
        let nullifier: Field = prev_note.compute_nullifier(&mut context, prev_note_hash);
        context.push_nullifier(nullifier);

        // create next note spent
        let new_note: AccountBasedNote = AccountBasedNote::new(
            viewing_key,
            prev_note.account_nonce + 1,
            prev_note.amount_spent + amount,
        );
        storage.spent_amounts.insert(new_note).emit(encode_and_encrypt_note(
            &mut context,
            sender,
            sender,
        ));

        // now check they have enough ofc
        let total_spent_after_tx: u128 = amount + prev_note.amount_spent;
        assert(received_amount >= total_spent_after_tx, "total_spent_after_tx is larger then historic received_amount");

        // homomorphically add the amount to the recipients received balance
        // and emit a event so recipient can reproduce their received balance
        increase_balance(
            sender,
            recipient,
            amount,

            contract_address,
            &mut context,
        );

    }

    #[public]
    #[internal]
    fn add_to_received_amount_amount(
        recipient: AztecAddress,
        added_amount_point: EmbeddedCurvePoint,
    ) {
        emit_event_in_public_log(
            PublicIncomingTransfer { recipient},
            &mut context,
        );
        let current_point: EmbeddedCurvePoint = storage.received_amounts.at(recipient).read();
        if (current_point.x == 0) {
            storage.received_amounts.at(recipient).write(added_amount_point);
        } else {
            let new_point: EmbeddedCurvePoint = embedded_curve_add(current_point, added_amount_point);
            storage.received_amounts.at(recipient).write(new_point);
        };
    }
}

