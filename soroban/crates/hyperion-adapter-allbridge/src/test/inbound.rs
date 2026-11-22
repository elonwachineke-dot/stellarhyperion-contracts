//! Tests for Allbridge inbound delivery resolution and validator verification.

use ed25519_dalek::{Signer, SigningKey};
use hyperion_core::{
    address::{assert_route_supports, StellarDestination},
    codec, AddressKind, HyperionError, RouteKind,
};
use hyperion_router::AdminAction;
use soroban_sdk::{
    testutils::{Address as _, Ledger},
    Address, BytesN, MuxedAddress, U256,
};

use super::setup::{World, ETH_CHAIN_ID, HUNDRED, NOWHERE_CHAIN_ID};
use crate::rail::{self, STELLAR_CHAIN_ID};

struct InboundSetup {
    world: World,
    signing_key: SigningKey,
    recipient: Address,
}

impl InboundSetup {
    fn new() -> Self {
        let world = World::new();
        let signing_key = SigningKey::from_bytes(&[55u8; 32]);
        let verifying_key = signing_key.verifying_key();
        let validator_pk = BytesN::from_array(&world.env, &verifying_key.to_bytes());

        // Configure the validator on the adapter.
        world.adapter().set_validator(&validator_pk);

        // Configure the adapter as the rail receiver on the router.
        world.run_action(AdminAction::SetRailReceiver(
            RouteKind::Allbridge,
            world.adapter_id.clone(),
        ));

        let recipient = Address::generate(&world.env);
        Self {
            world,
            signing_key,
            recipient,
        }
    }

    fn sign(
        &self,
        amount: u128,
        recipient: &Address,
        source_chain_id: u32,
        receive_token: &BytesN<32>,
        nonce: &U256,
    ) -> (BytesN<32>, BytesN<64>) {
        let env = &self.world.env;
        let (_, key) = codec::address_key(env, recipient).unwrap();
        let recipient_bytes = BytesN::from_array(env, &key);

        let message_id = rail::hash_message(
            env,
            amount,
            &recipient_bytes,
            source_chain_id,
            STELLAR_CHAIN_ID,
            receive_token,
            nonce,
        );

        let epoch = self.world.adapter().validator_epoch();
        let digest =
            rail::validator_attestation_digest(env, &self.world.adapter_id, &epoch, &message_id)
                .unwrap();
        let sig = self.signing_key.sign(&digest.to_array());
        let signature = BytesN::from_array(env, &sig.to_bytes());
        (message_id, signature)
    }

    fn token_key(&self) -> BytesN<32> {
        let env = &self.world.env;
        let key = codec::contract_key(env, &self.world.token_id).unwrap();
        BytesN::from_array(env, &key)
    }
}

// ------------------------------------------------------------------------------------------
// Happy path delivery
// ------------------------------------------------------------------------------------------

#[test]
fn a_valid_validator_signature_delivers_tokens_to_recipient() {
    let s = InboundSetup::new();
    let amount = HUNDRED;
    let nonce = U256::from_u32(&s.world.env, 101);
    let token_key = s.token_key();

    let (_message_id, signature) = s.sign(
        amount as u128,
        &s.recipient,
        ETH_CHAIN_ID,
        &token_key,
        &nonce,
    );

    // Fund the caller so the adapter can pull tokens.
    s.world.fund_user(amount);

    let claim_id = s.world.adapter().bridge_in(
        &s.world.user,
        &s.world.token_id,
        &amount,
        &s.recipient,
        &ETH_CHAIN_ID,
        &nonce,
        &signature,
    );

    assert_eq!(claim_id, 0);
    assert_eq!(s.world.token().balance(&s.recipient), amount);
}

#[test]
fn a_muxed_recipient_cannot_use_this_rail() {
    let s = InboundSetup::new();
    // There is no room for a muxed id in the 32-byte recipient word Allbridge signs. A muxed
    // destination is still a real Stellar address, but it is not one this route may resolve, and
    // `bridge_in` refuses that kind before it reads a signature or writes a claim.
    let dest = StellarDestination::muxed(BytesN::from_array(&s.world.env, &[0x11; 32]), 900);
    let encoded = dest.to_strkey(&s.world.env).unwrap();
    assert_eq!(MuxedAddress::from_string(&encoded).id(), Some(900));
    assert_eq!(dest.kind, AddressKind::MuxedAccount);
    assert_eq!(
        assert_route_supports(RouteKind::Allbridge, dest.kind),
        Err(HyperionError::MuxedNotSupported)
    );
}

#[test]
fn receive_alias_works_identically_to_bridge_in() {
    let s = InboundSetup::new();
    let amount = HUNDRED;
    let nonce = U256::from_u32(&s.world.env, 102);
    let token_key = s.token_key();

    let (_message_id, signature) = s.sign(
        amount as u128,
        &s.recipient,
        ETH_CHAIN_ID,
        &token_key,
        &nonce,
    );

    s.world.fund_user(amount);

    let claim_id = s.world.adapter().receive(
        &s.world.user,
        &s.world.token_id,
        &amount,
        &s.recipient,
        &ETH_CHAIN_ID,
        &nonce,
        &signature,
    );

    assert_eq!(claim_id, 0);
    assert_eq!(s.world.token().balance(&s.recipient), amount);
}

#[test]
fn an_account_with_no_trustline_parks_delivery_as_pending_claim() {
    let s = InboundSetup::new();
    let amount = HUNDRED;
    let nonce = U256::from_u32(&s.world.env, 104);
    let token_key = s.token_key();

    // Classic account with no trustline.
    let classic_key = [0x77u8; 32];
    let classic = Address::from_string(&codec::account_strkey(&s.world.env, &classic_key));

    let (_message_id, signature) =
        s.sign(amount as u128, &classic, ETH_CHAIN_ID, &token_key, &nonce);

    s.world.fund_user(amount);

    let claim_id = s.world.adapter().bridge_in(
        &s.world.user,
        &s.world.token_id,
        &amount,
        &classic,
        &ETH_CHAIN_ID,
        &nonce,
        &signature,
    );

    assert_eq!(claim_id, 1);
    assert_eq!(s.world.router().claim_count(), 1);
    let claim = s.world.router().get_claim(&1);
    assert_eq!(claim.recipient, classic);
    assert_eq!(claim.amount, amount);
    assert_eq!(claim.route, RouteKind::Allbridge);
    assert!(!claim.settled);
}

#[test]
fn pre_funded_adapter_does_not_pull_from_caller() {
    let s = InboundSetup::new();
    let amount = HUNDRED;
    let nonce = U256::from_u32(&s.world.env, 103);
    let token_key = s.token_key();

    let (_message_id, signature) = s.sign(
        amount as u128,
        &s.recipient,
        ETH_CHAIN_ID,
        &token_key,
        &nonce,
    );

    // Tokens were deposited directly into adapter (e.g. from pool payout).
    s.world.fund_adapter(amount);

    // Caller has 0 balance.
    let passer_by = Address::generate(&s.world.env);
    assert_eq!(s.world.token().balance(&passer_by), 0);

    let claim_id = s.world.adapter().bridge_in(
        &passer_by,
        &s.world.token_id,
        &amount,
        &s.recipient,
        &ETH_CHAIN_ID,
        &nonce,
        &signature,
    );

    assert_eq!(claim_id, 0);
    assert_eq!(s.world.token().balance(&s.recipient), amount);
}

// ------------------------------------------------------------------------------------------
// Replay protection
// ------------------------------------------------------------------------------------------

#[test]
fn the_same_message_cannot_be_delivered_twice() {
    let s = InboundSetup::new();
    let amount = HUNDRED;
    let nonce = U256::from_u32(&s.world.env, 201);
    let token_key = s.token_key();

    let (message_id, signature) = s.sign(
        amount as u128,
        &s.recipient,
        ETH_CHAIN_ID,
        &token_key,
        &nonce,
    );

    s.world.fund_user(amount * 2);

    assert_eq!(
        s.world.adapter().bridge_in(
            &s.world.user,
            &s.world.token_id,
            &amount,
            &s.recipient,
            &ETH_CHAIN_ID,
            &nonce,
            &signature,
        ),
        0
    );

    assert!(s.world.adapter().is_processed(&message_id));

    // Replay attempt must revert with ReplayedMessage.
    assert_eq!(
        s.world.adapter().try_bridge_in(
            &s.world.user,
            &s.world.token_id,
            &amount,
            &s.recipient,
            &ETH_CHAIN_ID,
            &nonce,
            &signature,
        ),
        Err(Ok(HyperionError::ReplayedMessage))
    );

    // Recipient received only once.
    assert_eq!(s.world.token().balance(&s.recipient), amount);
}

// ------------------------------------------------------------------------------------------
// Signature verification failures
// ------------------------------------------------------------------------------------------

#[test]
fn an_all_zero_signature_is_refused_as_unauthorized() {
    let s = InboundSetup::new();
    let amount = HUNDRED;
    let nonce = U256::from_u32(&s.world.env, 301);
    let zero_sig = BytesN::from_array(&s.world.env, &[0u8; 64]);

    s.world.fund_user(amount);

    assert_eq!(
        s.world.adapter().try_bridge_in(
            &s.world.user,
            &s.world.token_id,
            &amount,
            &s.recipient,
            &ETH_CHAIN_ID,
            &nonce,
            &zero_sig,
        ),
        Err(Ok(HyperionError::Unauthorized))
    );
}

#[test]
fn a_corrupted_signature_reverts() {
    let s = InboundSetup::new();
    let amount = HUNDRED;
    let nonce = U256::from_u32(&s.world.env, 302);
    let token_key = s.token_key();

    let (_message_id, signature) = s.sign(
        amount as u128,
        &s.recipient,
        ETH_CHAIN_ID,
        &token_key,
        &nonce,
    );

    // Tamper with the signature bytes.
    let mut sig_arr = signature.to_array();
    sig_arr[0] ^= 0xFF;
    let bad_sig = BytesN::from_array(&s.world.env, &sig_arr);

    s.world.fund_user(amount);

    assert!(s
        .world
        .adapter()
        .try_bridge_in(
            &s.world.user,
            &s.world.token_id,
            &amount,
            &s.recipient,
            &ETH_CHAIN_ID,
            &nonce,
            &bad_sig,
        )
        .is_err());

    assert_eq!(s.world.token().balance(&s.recipient), 0);
}

#[test]
fn a_signature_from_a_different_validator_reverts() {
    let s = InboundSetup::new();
    let amount = HUNDRED;
    let nonce = U256::from_u32(&s.world.env, 303);
    let token_key = s.token_key();

    // Sign with an impostor key.
    let impostor_key = SigningKey::from_bytes(&[99u8; 32]);
    let (_, key) = codec::address_key(&s.world.env, &s.recipient).unwrap();
    let recipient_bytes = BytesN::from_array(&s.world.env, &key);
    let message_id = rail::hash_message(
        &s.world.env,
        amount as u128,
        &recipient_bytes,
        ETH_CHAIN_ID,
        STELLAR_CHAIN_ID,
        &token_key,
        &nonce,
    );
    let sig = impostor_key.sign(&message_id.to_array());
    let bad_signature = BytesN::from_array(&s.world.env, &sig.to_bytes());

    s.world.fund_user(amount);

    assert!(s
        .world
        .adapter()
        .try_bridge_in(
            &s.world.user,
            &s.world.token_id,
            &amount,
            &s.recipient,
            &ETH_CHAIN_ID,
            &nonce,
            &bad_signature,
        )
        .is_err());

    assert_eq!(s.world.token().balance(&s.recipient), 0);
}

// ------------------------------------------------------------------------------------------
// Validation & Error Handling
// ------------------------------------------------------------------------------------------

#[test]
fn an_unconfigured_validator_reverts_with_rail_not_configured() {
    let world = World::new();
    let recipient = Address::generate(&world.env);
    let amount = HUNDRED;
    let nonce = U256::from_u32(&world.env, 401);
    let sig = BytesN::from_array(&world.env, &[1u8; 64]);

    world.fund_user(amount);

    assert_eq!(
        world.adapter().try_bridge_in(
            &world.user,
            &world.token_id,
            &amount,
            &recipient,
            &ETH_CHAIN_ID,
            &nonce,
            &sig,
        ),
        Err(Ok(HyperionError::RailNotConfigured))
    );
}

#[test]
fn an_unknown_source_chain_is_refused() {
    let s = InboundSetup::new();
    let amount = HUNDRED;
    let nonce = U256::from_u32(&s.world.env, 402);
    let token_key = s.token_key();

    let (_message_id, signature) = s.sign(
        amount as u128,
        &s.recipient,
        NOWHERE_CHAIN_ID,
        &token_key,
        &nonce,
    );

    s.world.fund_user(amount);

    assert_eq!(
        s.world.adapter().try_bridge_in(
            &s.world.user,
            &s.world.token_id,
            &amount,
            &s.recipient,
            &NOWHERE_CHAIN_ID,
            &nonce,
            &signature,
        ),
        Err(Ok(HyperionError::UnknownChain))
    );
}

#[test]
fn an_unmapped_token_is_refused() {
    let s = InboundSetup::new();
    let amount = HUNDRED;
    let nonce = U256::from_u32(&s.world.env, 403);
    let unmapped = s.world.orphan_id.clone();
    let key = codec::contract_key(&s.world.env, &unmapped).unwrap();
    let unmapped_token_key = BytesN::from_array(&s.world.env, &key);

    let (_message_id, signature) = s.sign(
        amount as u128,
        &s.recipient,
        ETH_CHAIN_ID,
        &unmapped_token_key,
        &nonce,
    );

    assert_eq!(
        s.world.adapter().try_bridge_in(
            &s.world.user,
            &unmapped,
            &amount,
            &s.recipient,
            &ETH_CHAIN_ID,
            &nonce,
            &signature,
        ),
        Err(Ok(HyperionError::TokenNotMapped))
    );
}

#[test]
fn a_zero_or_negative_amount_is_refused() {
    let s = InboundSetup::new();
    let nonce = U256::from_u32(&s.world.env, 404);
    let dummy_sig = BytesN::from_array(&s.world.env, &[1u8; 64]);

    assert_eq!(
        s.world.adapter().try_bridge_in(
            &s.world.user,
            &s.world.token_id,
            &0,
            &s.recipient,
            &ETH_CHAIN_ID,
            &nonce,
            &dummy_sig,
        ),
        Err(Ok(HyperionError::InvalidAmount))
    );

    assert_eq!(
        s.world.adapter().try_bridge_in(
            &s.world.user,
            &s.world.token_id,
            &-100,
            &s.recipient,
            &ETH_CHAIN_ID,
            &nonce,
            &dummy_sig,
        ),
        Err(Ok(HyperionError::InvalidAmount))
    );
}

// ------------------------------------------------------------------------------------------
// Admin & Configuration
// ------------------------------------------------------------------------------------------

#[test]
fn admin_can_set_and_read_validator() {
    let world = World::new();
    assert_eq!(
        world.adapter().try_get_validator(),
        Err(Ok(HyperionError::RailNotConfigured))
    );

    let pk = BytesN::from_array(&world.env, &[77u8; 32]);
    world.adapter().set_validator(&pk);
    assert_eq!(world.adapter().get_validator(), pk);
}

#[test]
#[should_panic(expected = "Unauthorized")]
fn non_admin_cannot_set_validator() {
    let world = World::new();
    world.env.set_auths(&[]);
    let pk = BytesN::from_array(&world.env, &[77u8; 32]);
    world.adapter().set_validator(&pk);
}

#[test]
fn validator_rotation_is_delayed_and_old_key_reuse_cannot_replay_an_old_epoch() {
    let s = InboundSetup::new();
    let w = &s.world;
    let nonce = U256::from_u32(&w.env, 900);
    let token = s.token_key();
    let (message, old_signature) =
        s.sign(HUNDRED as u128, &s.recipient, ETH_CHAIN_ID, &token, &nonce);
    let key2 = SigningKey::from_bytes(&[56; 32]);
    let pk2 = BytesN::from_array(&w.env, &key2.verifying_key().to_bytes());
    let initial = w.adapter().validator_epoch();
    assert_eq!(initial.epoch, 1);
    let at = w.adapter().queue_validator_rotation(&pk2);
    assert_eq!(
        w.adapter().try_set_validator(&pk2),
        Err(Ok(HyperionError::AlreadyConfigured))
    );
    assert_eq!(
        w.adapter().try_queue_validator_rotation(&pk2),
        Err(Ok(HyperionError::AlreadyConfigured))
    );
    assert_eq!(
        w.adapter().try_activate_validator_rotation(),
        Err(Ok(HyperionError::TimelockNotReady))
    );
    assert_eq!(w.adapter().validator_epoch(), initial);
    w.env.ledger().set_timestamp(at);
    assert_eq!(w.adapter().activate_validator_rotation(), 2);
    assert!(w
        .adapter()
        .try_bridge_in(
            &w.user,
            &w.token_id,
            &HUNDRED,
            &s.recipient,
            &ETH_CHAIN_ID,
            &nonce,
            &old_signature
        )
        .is_err());
    assert!(!w.adapter().is_processed(&message));
    assert_eq!(w.token().balance(&s.recipient), 0);
    let at = w.adapter().queue_validator_rotation(&initial.validator);
    w.env.ledger().set_timestamp(at);
    assert_eq!(w.adapter().activate_validator_rotation(), 3);
    assert!(w
        .adapter()
        .try_bridge_in(
            &w.user,
            &w.token_id,
            &HUNDRED,
            &s.recipient,
            &ETH_CHAIN_ID,
            &nonce,
            &old_signature
        )
        .is_err());
    let epoch = w.adapter().validator_epoch();
    let digest =
        rail::validator_attestation_digest(&w.env, &w.adapter_id, &epoch, &message).unwrap();
    let sig = BytesN::from_array(&w.env, &s.signing_key.sign(&digest.to_array()).to_bytes());
    w.adapter().bridge_in(
        &w.user,
        &w.token_id,
        &HUNDRED,
        &s.recipient,
        &ETH_CHAIN_ID,
        &nonce,
        &sig,
    );
    assert_eq!(w.token().balance(&s.recipient), HUNDRED);
    assert_eq!(
        w.adapter().try_bridge_in(
            &w.user,
            &w.token_id,
            &HUNDRED,
            &s.recipient,
            &ETH_CHAIN_ID,
            &nonce,
            &sig
        ),
        Err(Ok(HyperionError::ReplayedMessage))
    );
}

#[test]
fn epoch_attestations_bind_network_adapter_epoch_and_key_before_any_debit() {
    let s = InboundSetup::new();
    let w = &s.world;
    let nonce = U256::from_u32(&w.env, 901);
    let (message, _) = s.sign(
        HUNDRED as u128,
        &s.recipient,
        ETH_CHAIN_ID,
        &s.token_key(),
        &nonce,
    );
    let current = w.adapter().validator_epoch();
    let before = w.token().balance(&w.user);
    let foreign = Address::generate(&w.env);
    for mode in 0..4 {
        let mut epoch = current.clone();
        let adapter = if mode == 0 { &foreign } else { &w.adapter_id };
        if mode == 1 {
            epoch.epoch += 1;
        }
        if mode == 2 {
            epoch.validator = BytesN::from_array(&w.env, &[99; 32]);
        }
        let original = w.env.ledger().get();
        if mode == 3 {
            w.env.ledger().with_mut(|l| l.network_id = [9; 32]);
        }
        let digest = rail::validator_attestation_digest(&w.env, adapter, &epoch, &message).unwrap();
        w.env.ledger().set(original);
        let sig = BytesN::from_array(&w.env, &s.signing_key.sign(&digest.to_array()).to_bytes());
        assert!(w
            .adapter()
            .try_bridge_in(
                &w.user,
                &w.token_id,
                &HUNDRED,
                &s.recipient,
                &ETH_CHAIN_ID,
                &nonce,
                &sig
            )
            .is_err());
        assert_eq!(w.token().balance(&w.user), before);
        assert_eq!(w.token().balance(&w.adapter_id), 0);
        assert!(!w.adapter().is_processed(&message));
    }
}

#[test]
fn validator_legacy_storage_migrates_without_changing_accepted_epoch_zero_key() {
    let s = InboundSetup::new();
    let w = &s.world;
    let initial = w.adapter().validator_epoch();
    w.env.as_contract(&w.adapter_id, || {
        w.env
            .storage()
            .instance()
            .remove(&crate::storage::DataKey::ValidatorEpoch)
    });
    assert_eq!(w.adapter().validator_epoch().epoch, 0);
    w.adapter().set_validator(&initial.validator);
    assert_eq!(w.adapter().validator_epoch().epoch, 0);
    let nonce = U256::from_u32(&w.env, 902);
    let (message, sig) = s.sign(
        HUNDRED as u128,
        &s.recipient,
        ETH_CHAIN_ID,
        &s.token_key(),
        &nonce,
    );
    w.adapter().bridge_in(
        &w.user,
        &w.token_id,
        &HUNDRED,
        &s.recipient,
        &ETH_CHAIN_ID,
        &nonce,
        &sig,
    );
    assert!(w.adapter().is_processed(&message));
    let next = BytesN::from_array(
        &w.env,
        &SigningKey::from_bytes(&[56; 32]).verifying_key().to_bytes(),
    );
    assert_eq!(
        w.adapter().try_set_validator(&next),
        Err(Ok(HyperionError::AlreadyConfigured))
    );
    let at = w.adapter().queue_validator_rotation(&next);
    w.env.ledger().set_timestamp(at);
    assert_eq!(w.adapter().activate_validator_rotation(), 1);
    assert_eq!(w.adapter().get_validator(), next);
}

#[test]
fn rotation_cancel_overflow_and_unauthorized_calls_preserve_active_and_pending_state() {
    let s = InboundSetup::new();
    let w = &s.world;
    let original = w.adapter().validator_epoch();
    let next = BytesN::from_array(&w.env, &[88; 32]);
    assert_eq!(
        w.adapter().try_cancel_validator_rotation(),
        Err(Ok(HyperionError::RotationNotPending))
    );
    w.adapter().queue_validator_rotation(&next);
    w.adapter().cancel_validator_rotation();
    assert_eq!(w.adapter().validator_epoch(), original);
    assert_eq!(
        w.adapter().try_activate_validator_rotation(),
        Err(Ok(HyperionError::RotationNotPending))
    );
    w.env.ledger().set_timestamp(u64::MAX - 1);
    assert_eq!(
        w.adapter().try_queue_validator_rotation(&next),
        Err(Ok(HyperionError::DecimalOverflow))
    );
    w.env.ledger().set_timestamp(1_700_000_000);
    w.env.as_contract(&w.adapter_id, || {
        crate::storage::set_validator_epoch(
            &w.env,
            &crate::types::ValidatorEpoch {
                epoch: u32::MAX,
                validator: original.validator.clone(),
            },
        )
    });
    assert_eq!(
        w.adapter().try_queue_validator_rotation(&next),
        Err(Ok(HyperionError::DecimalOverflow))
    );
    assert!(w
        .env
        .as_contract(&w.adapter_id, || crate::storage::pending_validator(&w.env))
        .is_none());
    w.env.set_auths(&[]);
    assert!(w.adapter().try_set_emergency_disabled(&true).is_err());
    assert!(w.adapter().try_queue_validator_rotation(&next).is_err());
    assert!(w.adapter().try_activate_validator_rotation().is_err());
    assert!(w.adapter().try_cancel_validator_rotation().is_err());
}

#[test]
fn emergency_halts_new_custody_but_preserves_parked_claim_and_liability_across_rotation() {
    let s = InboundSetup::new();
    let w = &s.world;
    let recipient = Address::from_string(&codec::account_strkey(&w.env, &[77; 32]));
    let nonce = U256::from_u32(&w.env, 903);
    let (message, sig) = s.sign(
        HUNDRED as u128,
        &recipient,
        ETH_CHAIN_ID,
        &s.token_key(),
        &nonce,
    );
    let id = w.adapter().bridge_in(
        &w.user,
        &w.token_id,
        &HUNDRED,
        &recipient,
        &ETH_CHAIN_ID,
        &nonce,
        &sig,
    );
    let claim = w.router().get_claim(&id);
    let liability = w.router().claim_liability(&w.token_id);
    let balance = w.token().balance(&w.user);
    w.adapter().set_emergency_disabled(&true);
    assert!(!w.adapter().rail_open());
    assert!(w
        .router()
        .try_bridge_out(&w.user, &w.request(HUNDRED))
        .is_err());
    assert_eq!(w.token().balance(&w.user), balance);
    assert_eq!(
        w.adapter().try_bridge_in(
            &w.user,
            &w.token_id,
            &HUNDRED,
            &recipient,
            &ETH_CHAIN_ID,
            &nonce,
            &sig
        ),
        Err(Ok(HyperionError::Unauthorized))
    );
    let next = BytesN::from_array(&w.env, &[88; 32]);
    let at = w.adapter().queue_validator_rotation(&next);
    w.env.ledger().set_timestamp(at);
    w.adapter().activate_validator_rotation();
    assert_eq!(w.router().get_claim(&id), claim);
    assert_eq!(w.router().claim_liability(&w.token_id), liability);
    assert!(w.router().try_settle_claim(&w.user, &id).is_err());
    assert_eq!(w.router().claim_liability(&w.token_id), liability);
    assert!(w.adapter().is_processed(&message));
    w.adapter().set_emergency_disabled(&false);
    assert_eq!(
        w.adapter().try_bridge_in(
            &w.user,
            &w.token_id,
            &HUNDRED,
            &recipient,
            &ETH_CHAIN_ID,
            &nonce,
            &sig
        ),
        Err(Ok(HyperionError::ReplayedMessage))
    );
}
