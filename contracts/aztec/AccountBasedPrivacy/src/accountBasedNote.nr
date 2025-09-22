use dep::aztec::{
    context::PrivateContext,
    macros::notes::custom_note,
    note::note_interface::{NoteHash, NoteType},
    protocol_types::{
        hash::poseidon2_hash,
        traits::Serialize,
        traits::Packable,
    },
};
#[derive(Packable)] 
#[custom_note]
#[derive(Eq, Serialize)]
pub struct AccountBasedNote {
    pub viewing_key: Field,
    pub account_nonce: Field,   // starts at 0 goes up by 1 each spent
    pub amount_spent: u128,     // total spent on the account
}

impl AccountBasedNote {
    pub fn new(viewing_key: Field, account_nonce: Field, amount_spent: u128) -> Self {
        AccountBasedNote { viewing_key, account_nonce, amount_spent }
    }
}


// impl NoteType for AccountBasedNote {
//     fn get_id() -> Field {
//         // Pick a unique 7-bit integer for your note type, e.g., 77 <- chatGpt idk sound weird don't trust it
//         34
//     }
// }

impl NoteHash for AccountBasedNote {
    // just ignoring storage_slot for now
    fn compute_note_hash(self, storage_slot: Field) -> Field {
        poseidon2_hash([self.viewing_key, self.account_nonce, self.amount_spent as Field])
    }

    fn compute_nullifier(self,context: &mut PrivateContext, note_hash_for_nullify: Field) -> Field {
        poseidon2_hash([self.viewing_key, self.account_nonce])
    }

    unconstrained fn compute_nullifier_unconstrained(self, note_hash_for_nullify: Field) -> Field {
        poseidon2_hash([self.viewing_key, self.account_nonce])
    }
}