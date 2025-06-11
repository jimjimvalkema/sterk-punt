use dep::aztec::{macros::notes::note, protocol_types::{hash::poseidon2_hash, poseidon2, address::AztecAddress, traits::Serialize}};
use dep::aztec::macros::notes::{custom_note};
use dep::aztec::note::note_interface::{NoteHash};
use dep::aztec::context::{PrivateContext};
use aztec::note::note_interface::NoteHash::{compute_nullifier, compute_note_hash};

#[custom_note]
#[derive(Eq, Serialize)]
pub struct OneWayNote {
    secret: Field,
    account_nonce: Field,
    amount_spent: u128,
}

impl OneWayNote {
    pub fn new(secret: Field, account_nonce: Field, amount_spent: u128) -> Self {
        OneWayNote { secret, account_nonce, amount_spent }
    }
}

impl NoteHash for OneWayNote {
    // just ignoring storage_slot for now
    fn compute_note_hash(self, storage_slot: Field) -> Field {
        poseidon2_hash([self.secret, self.account_nonce, self.amount_spent as Field])
    }

    fn compute_nullifier(self,context: &mut PrivateContext, note_hash_for_nullify: Field) -> Field {
        // - 1 is weird since it will underflow at the first tx. But thats fine since we are not nullifying anything
        poseidon2_hash([self.secret, self.account_nonce - 1])
    }

    unconstrained fn compute_nullifier_unconstrained(self, note_hash_for_nullify: Field) -> Field {
        poseidon2_hash([self.secret, self.account_nonce - 1])
    }
}