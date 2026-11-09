//! API-equivalent prices in USD per million tokens, per model, turning a usage tally into what the
//! work would have cost on the API — an estimate, never a bill. Defaults plus `prices:` overrides
//! in config.yml.

use std::collections::HashMap;

use crate::data_root;
use crate::price_defaults::DEFAULTS;
use crate::project_config::{LoadFailure, ProjectConfig};
use crate::ruby_num::{sum, Num};
use crate::transcript_usage::{Buckets, KINDS};

pub struct PriceTable {
    rates: HashMap<String, [Option<Num>; 5]>,
}

impl PriceTable {
    /// Defaults merged with config.yml's `prices:` (`ProjectConfig::prices`); a broken config falls back to
    /// the defaults.
    pub fn load() -> PriceTable {
        let config = ProjectConfig::current();
        match config.failure() {
            Some(LoadFailure::Syntax(message)) => data_root::log_error("price-table", "Psych::SyntaxError", message),
            Some(LoadFailure::NotMapping) => data_root::log_error("price-table", "TypeError", "no implicit conversion of String into Integer"),
            None => {}
        }
        PriceTable::new(config.prices())
    }

    pub fn new(overrides: &[(String, Vec<(usize, Num)>)]) -> PriceTable {
        let mut rates: HashMap<String, [Option<Num>; 5]> = DEFAULTS
            .iter()
            .map(|(model, r)| (model.to_string(), [Some(Num::literal(r[0])), Some(Num::literal(r[1])), Some(Num::literal(r[2])), Some(Num::literal(r[3])), Some(Num::literal(r[4]))]))
            .collect();
        for (model, fields) in overrides {
            let entry = rates.entry(model.clone()).or_insert([None; 5]);
            for (i, number) in fields {
                entry[*i] = Some(*number);
            }
        }
        PriceTable { rates }
    }

    /// The rates for a bucket key: exact, else with its variants dropped from the end.
    fn rates_for(&self, bucket: &str) -> Option<[Num; 5]> {
        let mut parts: Vec<&str> = bucket.split(':').collect();
        while !parts.is_empty() {
            if let Some(r) = self.rates.get(&parts.join(":")) {
                if r.iter().all(Option::is_some) {
                    return Some([r[0].unwrap(), r[1].unwrap(), r[2].unwrap(), r[3].unwrap(), r[4].unwrap()]);
                }
            }
            parts.pop();
        }
        None
    }

    /// (dollars, unpriced bucket keys) for a tally of buckets.
    pub fn cost(&self, buckets: &Buckets) -> (Num, Vec<String>) {
        let mut unpriced = vec![];
        let terms: Vec<Num> = buckets
            .iter()
            .map(|(bucket, tokens)| match self.rates_for(bucket) {
                None => {
                    unpriced.push(bucket.clone());
                    Num::Int(0)
                }
                Some(rates) => {
                    let spent = sum(KINDS.iter().enumerate().map(|(i, k)| {
                        Num::Int(tokens.get(k).and_then(serde_json::Value::as_i64).unwrap_or(0) as i128).mul(rates[i])
                    }));
                    Num::Float(spent.to_f64() / 1_000_000.0)
                }
            })
            .collect();
        (sum(terms), unpriced)
    }
}
