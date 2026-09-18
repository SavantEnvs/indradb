//! mayhem/kat — known-answer probe used by mayhem/test.sh.
//!
//! Built with the project's NORMAL (non-nightly, non-sanitized) flags in
//! build.sh, so it is a plain dynamically-linked Rust binary (Rust binaries
//! dynamically link libc by default) and therefore reachable by verify-repo's
//! LD_PRELOAD sabotage shim: a neutered build prints nothing and every
//! `kat_expect` in test.sh fails.
//!
//! Every line below is `KEY=VALUE`; test.sh grep -x matches full lines, so the
//! printed form must be exactly reproduced in test.sh's expected strings.
//! Every assertion here exercises the pure in-memory `MemoryDatastore` (no
//! filesystem, no network) end to end: vertex/edge creation, duplicate-id
//! rejection, the `Query`/pipe engine, property set+fetch, bulk insert, and
//! `Identifier` validation.

use indradb::{
    BulkInsertItem, CountQueryExt, Database, Edge, Identifier, Json, MemoryDatastore, Query, QueryExt,
    QueryOutputValue, SpecificEdgeQuery, SpecificVertexQuery, Vertex,
};
use uuid::Uuid;

fn main() {
    let db = MemoryDatastore::new_db();

    let t_person = Identifier::new("person").unwrap();
    let t_likes = Identifier::new("likes").unwrap();

    let v1_id = Uuid::from_u128(1);
    let v2_id = Uuid::from_u128(2);
    let v1 = Vertex::with_id(v1_id, t_person);
    let v2 = Vertex::with_id(v2_id, t_person);

    // 1) vertex creation, incl. duplicate-id rejection.
    println!("KAT_CREATE_V1={}", db.create_vertex(&v1).unwrap());
    println!("KAT_CREATE_V2={}", db.create_vertex(&v2).unwrap());
    println!("KAT_CREATE_V1_DUP={}", db.create_vertex(&v1).unwrap());

    // 2) edge creation.
    let edge = Edge::new(v1_id, t_likes, v2_id);
    println!("KAT_CREATE_EDGE={}", db.create_edge(&edge).unwrap());

    // 3) the Query engine: fetch the two vertices back by ID.
    let vq: Query = SpecificVertexQuery::new(vec![v1_id, v2_id]).into();
    let vresults = db.get(vq).unwrap();
    let vcount = match &vresults[0] {
        QueryOutputValue::Vertices(vs) => vs.len(),
        other => panic!("unexpected query output: {other:?}"),
    };
    println!("KAT_QUERY_VERTEX_COUNT={vcount}");

    let eq: Query = SpecificEdgeQuery::new(vec![edge.clone()]).into();
    let eresults = db.get(eq).unwrap();
    let ecount = match &eresults[0] {
        QueryOutputValue::Edges(es) => es.len(),
        other => panic!("unexpected query output: {other:?}"),
    };
    println!("KAT_QUERY_EDGE_COUNT={ecount}");

    // 4) property set + fetch (round-trips through the same Query pipeline).
    let age_id = Identifier::new("age").unwrap();
    let age_val = Json::new(serde_json::json!(30));
    let set_q: Query = SpecificVertexQuery::new(vec![v1_id]).into();
    db.set_properties(set_q, age_id, &age_val).unwrap();

    let prop_q: Query = SpecificVertexQuery::new(vec![v1_id]).properties().unwrap().into();
    let presults = db.get(prop_q).unwrap();
    let age_value = match &presults[0] {
        QueryOutputValue::VertexProperties(vps) => vps[0].props[0].value.to_string(),
        other => panic!("unexpected query output: {other:?}"),
    };
    println!("KAT_VERTEX_PROPERTY_AGE={age_value}");

    // 5) bulk insert (a third vertex + a second edge in one call), then a
    //    Count query over ALL vertices to confirm the datastore now holds 3.
    let v3_id = Uuid::from_u128(3);
    let items = vec![
        BulkInsertItem::Vertex(Vertex::with_id(v3_id, t_person)),
        BulkInsertItem::Edge(Edge::new(v2_id, t_likes, v3_id)),
    ];
    println!("KAT_BULK_INSERT_OK={}", db.bulk_insert(items).is_ok());

    let count_q: Query = indradb::AllVertexQuery.count().unwrap().into();
    let cresults = db.get(count_q).unwrap();
    let total_vertices = match &cresults[0] {
        QueryOutputValue::Count(n) => *n,
        other => panic!("unexpected query output: {other:?}"),
    };
    println!("KAT_TOTAL_VERTEX_COUNT={total_vertices}");

    // 6) Identifier validation: a rejected (too-long, 256-char) identifier and
    //    a rejected (invalid-character) identifier, proving the parser
    //    actually rejects bad input rather than accepting everything.
    let too_long: String = std::iter::repeat('x').take(256).collect();
    println!("KAT_IDENTIFIER_TOO_LONG_REJECTED={}", Identifier::new(too_long).is_err());
    println!(
        "KAT_IDENTIFIER_INVALID_CHAR_REJECTED={}",
        Identifier::new("$".to_string()).is_err()
    );
    println!("KAT_IDENTIFIER_VALID_ACCEPTED={}", Identifier::new("ok_1".to_string()).is_ok());
}
