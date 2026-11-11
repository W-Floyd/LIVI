//! An in-process stand-in for livi-core: replays fixture state to a real `Client` over a
//! socketpair and records what the client sends back.

use std::io::{self, ErrorKind, Read, Write};
use std::os::unix::net::UnixStream;

use livi_core_proto::PROTOCOL;
use livi_core_proto::frame::{Decoder, encode};
use livi_core_proto::message::{FromCore, ToCore};
use livi_core_proto::patch::PatchOp;
use livi_core_proto::state::State;
use serde_json::Value;

pub struct FakeCore {
    stream: UnixStream,
    decoder: Decoder,
    rev: u64,
    sent: Vec<ToCore>,
}

impl FakeCore {
    /// Returns the fake and the client's end of the socket.
    pub fn new() -> io::Result<(FakeCore, UnixStream)> {
        let (ours, theirs) = UnixStream::pair()?;
        // Reads drain only what the client has already written: its writes are synchronous,
        // so a nonblocking read after them sees everything, with no reader thread to race.
        ours.set_nonblocking(true)?;
        let fake = FakeCore {
            stream: ours,
            decoder: Decoder::new(),
            rev: 0,
            sent: Vec::new(),
        };
        Ok((fake, theirs))
    }

    /// `fixture` is a partial state; `State::filled` supplies the rest, as the real core would.
    pub fn welcome(&mut self, fixture: Value) -> io::Result<()> {
        let state: State = serde_json::from_value(State::filled(fixture))
            .map_err(|e| io::Error::new(ErrorKind::InvalidData, e))?;
        self.write(&FromCore::Welcome {
            protocol: PROTOCOL,
            version: "fake".into(),
            rev: self.rev,
            state: Box::new(state),
        })
    }

    pub fn set(&mut self, path: Vec<String>, value: Value) -> io::Result<()> {
        self.rev += 1;
        self.write(&FromCore::Patch {
            rev: self.rev,
            ops: vec![PatchOp::Set { path, value }],
        })
    }

    pub fn open_page(&mut self, path: String) -> io::Result<()> {
        self.write(&FromCore::OpenPage { path })
    }

    /// Everything the client has sent so far, oldest first.
    pub fn sent(&mut self) -> &[ToCore] {
        let mut buf = [0u8; 16 * 1024];
        loop {
            match self.stream.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => self.decoder.push(&buf[..n]),
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
        while let Some(msg) = self.decoder.next_message::<ToCore>() {
            match msg {
                Ok(msg) => self.sent.push(msg),
                Err(e) => eprintln!("[fake-core] {e}"),
            }
        }
        &self.sent
    }

    pub fn clear(&mut self) {
        self.sent();
        self.sent.clear();
    }

    fn write(&mut self, msg: &FromCore) -> io::Result<()> {
        let bytes = encode(msg).map_err(|e| io::Error::new(ErrorKind::InvalidData, e))?;
        // Nonblocking: a frame larger than the socket buffer waits for the client's reader.
        let mut rest = &bytes[..];
        while !rest.is_empty() {
            match self.stream.write(rest) {
                Ok(n) => rest = &rest[n..],
                Err(e) if e.kind() == ErrorKind::WouldBlock => std::thread::yield_now(),
                Err(e) if e.kind() == ErrorKind::Interrupted => {}
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc;
    use std::time::Duration;

    use livi_core_client::{Client, Event};
    use livi_core_proto::message::Action;
    use serde_json::json;

    use super::*;

    #[test]
    fn a_client_sees_the_fixture_and_its_patches_and_its_actions_are_recorded() {
        let (mut fake, theirs) = FakeCore::new().unwrap();
        let (tx, rx) = mpsc::channel();
        let client = Client::start(theirs, "test", move |ev, _| {
            let _ = tx.send(ev);
        })
        .unwrap();
        let next = || rx.recv_timeout(Duration::from_secs(5)).unwrap();

        fake.welcome(json!({ "telemetry": { "fuelPct": 64.0 } }))
            .unwrap();
        assert!(matches!(next(), Event::Welcome { .. }));
        assert_eq!(client.mirror().json["telemetry"]["fuelPct"], 64.0);

        fake.set(vec!["telemetry".into(), "fuelPct".into()], json!(63.0))
            .unwrap();
        assert!(matches!(next(), Event::Changed(_)));
        assert_eq!(client.mirror().json["telemetry"]["fuelPct"], 63.0);

        client.act(Action::PreconditionBattery { on: true });
        let sent = fake.sent().to_vec();
        assert!(matches!(sent[0], ToCore::Hello { .. }));
        assert!(matches!(
            sent[1],
            ToCore::Action {
                action: Action::PreconditionBattery { on: true },
                ..
            }
        ));
        fake.clear();
        assert!(fake.sent().is_empty());
    }
}
