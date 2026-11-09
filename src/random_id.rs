//! Random ids from the system's entropy: a run id (8 lowercase alphanumerics, safe in a tmux name) and the
//! session id qm hands claude (a version 4 uuid).

use std::io::Read;

fn bytes(n: usize) -> Vec<u8> {
    let mut out = vec![0u8; n];
    if std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut out)).is_err() {
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
        for (i, b) in out.iter_mut().enumerate() {
            *b = (nanos >> ((i % 16) * 8)) as u8 ^ (std::process::id() as u8).wrapping_mul(i as u8 + 1);
        }
    }
    out
}

/// `n` characters of `[a-z0-9]`.
pub fn alphanumeric(n: usize) -> String {
    const ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";
    // 252 = 7 * 36: the bytes above it would bias the draw
    let mut out = String::new();
    while out.len() < n {
        out.extend(bytes(n * 2).into_iter().filter(|b| *b < 252).map(|b| ALPHABET[b as usize % 36] as char).take(n - out.len()));
    }
    out
}

/// `SecureRandom.uuid`.
pub fn uuid() -> String {
    let mut b = bytes(16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let hex: Vec<String> = b.iter().map(|x| format!("{x:02x}")).collect();
    format!("{}-{}-{}-{}-{}", hex[0..4].concat(), hex[4..6].concat(), hex[6..8].concat(), hex[8..10].concat(), hex[10..16].concat())
}

#[cfg(test)]
mod tests {
    #[test]
    fn ids_have_their_shapes() {
        let id = super::alphanumeric(8);
        assert!(id.len() == 8 && id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()), "{id}");
        let uuid = super::uuid();
        let re = regex::Regex::new(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$").unwrap();
        assert!(re.is_match(&uuid), "{uuid}");
        assert_ne!(super::uuid(), uuid);
    }
}
