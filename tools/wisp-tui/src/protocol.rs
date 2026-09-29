//! The JSON Lines protocol `wisp chat --json` speaks (see `docs/wisp.md`, "Headless chat").

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One line from wisp.
#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Outbound {
    /// A whole line of output, as `/help` prints.
    Output {
        /// The text.
        text: String,
    },
    /// A fragment of the streamed reply.
    Delta {
        /// The text, no newline of its own.
        text: String,
    },
    /// A note from wisp itself.
    Note {
        /// The text.
        text: String,
    },
    /// The status before a prompt: the turn is over and input is wanted.
    Status(Status),
    /// A turn's start or end.
    Turn(Turn),
    /// What the turn under way is doing; `doing` is `None` when it has ended.
    Activity {
        /// Such as `running git status` or `waiting for the model`.
        doing: Option<String>,
        /// Whether a person is being asked.
        #[serde(default)]
        asking: bool,
        /// Seconds from the turn's start to when this began.
        #[serde(rename = "turnSeconds", default)]
        turn_seconds: f64,
    },
    /// An audit event of the conversation.
    Event(Event),
    /// An approval the front end must answer.
    Approval(Approval),
    /// A choice a chat command asks, such as `/config set`.
    Choice(Choice),
    /// Candidates for a `complete` request.
    Completions {
        /// The request's id.
        id: String,
        /// The character index where the word being completed starts.
        from: usize,
        /// The words that fit.
        #[serde(default)]
        candidates: Vec<String>,
    },
    /// wisp is exiting.
    Exit,
    /// Anything this version does not know.
    #[serde(other)]
    Unknown,
}

/// The status line's facts.
#[derive(Debug, Clone, Deserialize, PartialEq, Default)]
pub struct Status {
    /// The model selection.
    pub model: String,
    /// The working directory, abbreviated.
    pub directory: String,
    /// The git branch, when in a repository.
    pub branch: Option<String>,
    /// Whether tracked files have changes, when known.
    pub dirty: Option<bool>,
    /// The approval mode.
    pub approval: String,
    /// Fraction of the context window used, when known.
    #[serde(rename = "contextUsed")]
    pub context_used: Option<f64>,
}

/// One edge of a turn: a message to the model and everything it does to answer it.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Turn {
    /// `start` or `end`.
    pub phase: String,
    /// The number the turn's audit events carry.
    #[serde(rename = "turn")]
    pub number: u64,
    /// At the end, how long the turn took.
    pub seconds: Option<f64>,
    /// At the end, `ok` or `error`.
    pub outcome: Option<String>,
    /// At the end, the prompt tokens the turn's requests read, when the model reports them.
    #[serde(rename = "inputTokens")]
    pub input_tokens: Option<u64>,
    /// At the end, the tokens the turn wrote, when the model reports them.
    #[serde(rename = "outputTokens")]
    pub output_tokens: Option<u64>,
}

impl Turn {
    /// Whether this is the turn's start.
    pub fn is_start(&self) -> bool {
        self.phase == "start"
    }
}

/// An audit event: kind, details, and the line wisp's terminal chat shows for it.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Event {
    /// `tool.call`, `tool.result`, `command.outcome`, `file.write`, `context.condensation`, `error`, and so on.
    pub kind: String,
    /// The call id pairing a call with its result.
    pub call: Option<String>,
    /// Kind-specific fields.
    #[serde(default)]
    pub details: Value,
    /// The line to show, worded by wisp so every face agrees; `None` for events chat does not show.
    #[serde(default)]
    pub text: Option<String>,
}

/// One answer a choice offers.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct ChoiceOption {
    /// What choosing it answers.
    pub value: String,
    /// What it is called.
    pub label: String,
    /// A line about it, or empty.
    #[serde(default)]
    pub detail: String,
}

/// A question with answers to pick from.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct Choice {
    /// The id to answer with.
    pub id: String,
    /// The question.
    pub title: String,
    /// The answers on offer; empty when only typed text will do.
    #[serde(default)]
    pub options: Vec<ChoiceOption>,
    /// The value in force now.
    pub current: Option<String>,
    /// Whether typed text is taken as well as an option.
    #[serde(rename = "acceptsText", default)]
    pub accepts_text: bool,
}

/// An approval request.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Approval {
    /// The id to answer with.
    pub id: String,
    /// The simple command judged.
    pub command: String,
    /// The whole line it is part of.
    pub line: String,
    /// The pattern the answer is remembered under.
    pub pattern: String,
    /// The working directory.
    pub directory: String,
    /// `safe`, `moderate`, or `dangerous`.
    pub level: String,
    /// Why.
    #[serde(default)]
    pub reasons: Vec<String>,
}

/// One line to wisp.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Inbound {
    /// A chat line, slash commands included.
    Message {
        /// The text.
        text: String,
    },
    /// A request for completions of the input line at a character index.
    Complete {
        /// The id the answer carries.
        id: String,
        /// The input line.
        text: String,
        /// The cursor, in characters.
        cursor: usize,
    },
    /// An answer to a choice; `None` is no answer.
    Choose {
        /// The choice's id.
        id: String,
        /// The value chosen.
        value: Option<String>,
    },
    /// An answer to an approval.
    Answer {
        /// The approval's id.
        id: String,
        /// `once`, `session`, `project`, `always`, or `no`.
        decision: String,
    },
}

impl Outbound {
    /// Parses one line; a line that is not JSON is shown as a note, so nothing is lost.
    pub fn parse(line: &str) -> Self {
        serde_json::from_str(line).unwrap_or_else(|_| Self::Note {
            text: line.to_string(),
        })
    }
}

impl Inbound {
    /// The line to write, newline included.
    pub fn line(&self) -> String {
        let mut text = serde_json::to_string(self).unwrap_or_else(|_| String::from("{}"));
        text.push('\n');
        text
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_every_outbound_shape() {
        assert_eq!(
            Outbound::parse(r#"{"type":"delta","text":"hi"}"#),
            Outbound::Delta { text: "hi".into() }
        );
        let status = Outbound::parse(
            r#"{"type":"status","model":"system","directory":"~","branch":null,"dirty":true,"approval":"--yes","contextUsed":0.25}"#,
        );
        match status {
            Outbound::Status(s) => {
                assert_eq!(s.model, "system");
                assert_eq!(s.branch, None);
                assert_eq!(s.dirty, Some(true));
                assert_eq!(s.context_used, Some(0.25));
            }
            other => panic!("not a status: {other:?}"),
        }
        let event = Outbound::parse(
            r#"{"type":"event","kind":"tool.call","call":"c","details":{"tool":"read_file"}}"#,
        );
        match event {
            Outbound::Event(e) => {
                assert_eq!(e.details["tool"], "read_file");
                assert_eq!(e.text, None);
            }
            other => panic!("not an event: {other:?}"),
        }
        let shown = Outbound::parse(
            r#"{"type":"event","kind":"tool.call","call":"c","details":{},"text":"⚙ read_file a"}"#,
        );
        assert!(matches!(shown, Outbound::Event(e) if e.text.as_deref() == Some("⚙ read_file a")));
        let start = Outbound::parse(r#"{"type":"turn","phase":"start","turn":2}"#);
        assert!(
            matches!(&start, Outbound::Turn(t) if t.is_start() && t.number == 2 && t.seconds.is_none())
        );
        let end = Outbound::parse(
            r#"{"type":"turn","phase":"end","turn":2,"seconds":1.5,"outcome":"error"}"#,
        );
        assert!(
            matches!(&end, Outbound::Turn(t) if !t.is_start() && t.outcome.as_deref() == Some("error"))
        );
        let choice = Outbound::parse(
            r#"{"type":"choice","id":"c","title":"pick","options":[{"value":"a","label":"A","detail":""}],"current":null,"acceptsText":true}"#,
        );
        assert!(
            matches!(&choice, Outbound::Choice(c) if c.options[0].label == "A" && c.accepts_text && c.current.is_none())
        );
        assert_eq!(
            Inbound::Choose {
                id: "c".into(),
                value: None
            }
            .line(),
            "{\"type\":\"choose\",\"id\":\"c\",\"value\":null}\n"
        );
        assert_eq!(
            Outbound::parse(
                r#"{"type":"completions","id":"k1","from":0,"candidates":["/config"]}"#
            ),
            Outbound::Completions {
                id: "k1".into(),
                from: 0,
                candidates: vec!["/config".into()]
            }
        );
        assert_eq!(
            Inbound::Complete {
                id: "k1".into(),
                text: "/con".into(),
                cursor: 4
            }
            .line(),
            "{\"type\":\"complete\",\"id\":\"k1\",\"text\":\"/con\",\"cursor\":4}\n"
        );
        assert_eq!(Outbound::parse(r#"{"type":"exit"}"#), Outbound::Exit);
        assert_eq!(Outbound::parse(r#"{"type":"future"}"#), Outbound::Unknown);
        assert_eq!(
            Outbound::parse("plain text"),
            Outbound::Note {
                text: "plain text".into()
            }
        );
    }

    #[test]
    fn writes_inbound_lines() {
        assert_eq!(
            Inbound::Message {
                text: "/help".into()
            }
            .line(),
            "{\"type\":\"message\",\"text\":\"/help\"}\n"
        );
        assert_eq!(
            Inbound::Answer {
                id: "a".into(),
                decision: "session".into()
            }
            .line(),
            "{\"type\":\"answer\",\"id\":\"a\",\"decision\":\"session\"}\n"
        );
    }
}
