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
        /// Whether the model is thinking (ADR 0053); absent, and so false, otherwise.
        #[serde(default)]
        thinking: bool,
    },
    /// An audit event of the conversation.
    Event(Event),
    /// An approval the front end must answer.
    Approval(Approval),
    /// A choice a chat command asks, such as `/config set`.
    Choice(Choice),
    /// A view a chat command asks for, such as `/inspect context next`.
    View(View),
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
    /// A notification for the front end to post (ADR 0044), sent only when `hello` declared `notify`.
    Notify(Notice),
    /// An approval shown earlier that no longer waits: answered another way, withdrawn, or expired.
    Withdrawn {
        /// The approval's id.
        id: String,
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
    /// Lines added in tracked files since the last commit, when known.
    pub added: Option<u64>,
    /// Lines removed, when known.
    pub removed: Option<u64>,
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
    /// At the end, the line of what the turn ran, from its audit events (ADR 0051), shown under the reply;
    /// absent when there is nothing to show.
    pub ran: Option<String>,
    /// At the end, the line naming the entries the reply cites that the conversation does not hold (ADR 0055),
    /// shown beside `ran`; absent when there are none.
    #[serde(default)]
    pub cited: Option<String>,
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
    /// For `tool.result`, the tool's output; absent for every other kind and for older wisps.
    #[serde(default)]
    pub output: Option<ToolOutput>,
}

/// Lines of a tool's output the terminal chat shows before folding, when wisp does not say.
pub const DEFAULT_SHOWN_LINES: usize = 20;

fn default_shown_lines() -> usize {
    DEFAULT_SHOWN_LINES
}

/// A tool's output, as far as wisp sent it.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct ToolOutput {
    /// The `tool.result` event's id.
    #[serde(default)]
    pub id: String,
    /// The output, up to 16 KiB.
    #[serde(default)]
    pub text: String,
    /// Lines in the whole output.
    #[serde(default)]
    pub lines: u64,
    /// Bytes in the whole output.
    #[serde(default)]
    pub bytes: u64,
    /// Whether `text` is shorter than the output.
    #[serde(default)]
    pub truncated: bool,
    /// Lines to show before folding; 0 shows none.
    #[serde(rename = "shownLines", default = "default_shown_lines")]
    pub shown_lines: usize,
}

/// A view answering a chat command: Markdown text for a panel.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct View {
    /// `context` or `turns`.
    pub kind: String,
    /// For `context`, the turn it was composed for; `None` is the next request.
    #[serde(default)]
    pub turn: Option<u64>,
    /// How many turns the conversation has had.
    #[serde(default)]
    pub turns: u64,
    /// The Markdown.
    #[serde(default)]
    pub text: String,
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

/// An approval request: this conversation's, or (with `source` `mcp`) a command waiting in a `wisp mcp`
/// server, which wisp sends because `hello` declared `approve-mcp` (ADR 0046), or (with `kind` `fact`) a
/// fact a `wisp mcp` caller asked to keep as a permanent fact, sent because `hello` declared `keep-facts`
/// (ADR 0048).
#[derive(Debug, Clone, Deserialize, PartialEq, Default)]
pub struct Approval {
    /// The id to answer with.
    pub id: String,
    /// The simple command judged; for a fact, the fact as one line.
    #[serde(default)]
    pub command: String,
    /// The whole line it is part of.
    #[serde(default)]
    pub line: String,
    /// The pattern the answer is remembered under; empty for a fact.
    #[serde(default)]
    pub pattern: String,
    /// The working directory; empty for a fact.
    #[serde(default)]
    pub directory: String,
    /// `safe`, `moderate`, or `dangerous`.
    #[serde(default)]
    pub level: String,
    /// Why.
    #[serde(default)]
    pub reasons: Vec<String>,
    /// `mcp` for a command waiting in a `wisp mcp` server; absent for this conversation's own.
    #[serde(default)]
    pub source: Option<String>,
    /// For `mcp`, the thread it is for.
    #[serde(default)]
    pub thread: Option<String>,
    /// For `mcp`, the client that called.
    #[serde(default)]
    pub client: Option<String>,
    /// `fact` for a fact to keep; absent for a command.
    #[serde(default)]
    pub kind: Option<String>,
    /// For a fact to keep, the fact.
    #[serde(default)]
    pub fact: Option<FactAsk>,
}

/// The fact a `wisp mcp` caller asked to keep as a permanent fact, as its thread holds it.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq, Default)]
pub struct FactAsk {
    /// Its id in the thread (`c3`) or the session (`s1`).
    #[serde(default)]
    pub id: String,
    /// The subject kind, such as `entity`.
    #[serde(default)]
    pub subject: String,
    /// The name under the subject.
    #[serde(default)]
    pub name: String,
    /// The value.
    #[serde(default)]
    pub value: String,
    /// Who asserted it: `tool`, `model`, `caller`, or `person`.
    #[serde(default)]
    pub source: String,
}

impl Approval {
    /// Whether it waits in a `wisp mcp` server rather than in this conversation.
    pub fn is_mcp(&self) -> bool {
        self.source.as_deref() == Some("mcp")
    }

    /// Whether it asks to keep a fact rather than to run a command; answered `keep` or `drop`.
    pub fn is_fact(&self) -> bool {
        self.kind.as_deref() == Some("fact")
    }
}

/// A notification wisp asks the front end to post: already bounded and rate-limited by wisp, but
/// sanitised again before it goes into an escape sequence.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct Notice {
    /// The first line.
    #[serde(default)]
    pub title: String,
    /// A second line under the title, when there is one.
    #[serde(default)]
    pub subtitle: Option<String>,
    /// The message.
    #[serde(default)]
    pub body: String,
    /// Whether wisp would play a sound; the terminal sequences have no use for it.
    #[serde(default)]
    pub sound: bool,
}

/// One line to wisp.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Inbound {
    /// The first line: which effects this front end carries for wisp (ADR 0044), and who it is.
    Hello {
        /// `approve`, and `notify` when the terminal can post a notification.
        effects: Vec<String>,
        /// The front end's name.
        client: String,
        /// Its version.
        version: String,
    },
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
    /// This front end's `hello`: it answers approvals, its own and those waiting in `wisp mcp` servers,
    /// and requests to keep facts from `wisp mcp` callers, and posts notifications when `notify` is true.
    pub fn hello(notify: bool) -> Self {
        let mut effects = vec![
            String::from("approve"),
            String::from("approve-mcp"),
            String::from("keep-facts"),
        ];
        if notify {
            effects.push(String::from("notify"));
        }
        Self::Hello {
            effects,
            client: String::from("wisp-tui"),
            version: String::from(env!("CARGO_PKG_VERSION")),
        }
    }

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
    #[allow(clippy::too_many_lines)]
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
        let ran = Outbound::parse(
            r#"{"type":"turn","phase":"end","turn":3,"seconds":1,"outcome":"ok","ran":"ran: read_file ×2"}"#,
        );
        assert!(matches!(&ran, Outbound::Turn(t) if t.ran.as_deref() == Some("ran: read_file ×2")));
        let cited = Outbound::parse(
            r#"{"type":"turn","phase":"end","turn":3,"cited":"cited but not in this conversation: entries 19–30 (12)"}"#,
        );
        assert!(
            matches!(&cited, Outbound::Turn(t) if t.cited.as_deref() == Some("cited but not in this conversation: entries 19–30 (12)"))
        );
        assert!(matches!(&end, Outbound::Turn(t) if t.ran.is_none()));
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
        let result = Outbound::parse(
            r#"{"type":"event","kind":"tool.result","call":"c","details":{},"text":"ok","future":1,"output":{"id":"0123456789abcdef","text":"a\nb\n","lines":2,"bytes":4,"truncated":false,"shownLines":1,"extra":true}}"#,
        );
        match result {
            Outbound::Event(e) => {
                let Some(output) = e.output else {
                    panic!("no output");
                };
                assert_eq!(output.id, "0123456789abcdef");
                assert_eq!(output.text, "a\nb\n");
                assert_eq!((output.lines, output.bytes), (2, 4));
                assert!(!output.truncated);
                assert_eq!(output.shown_lines, 1);
            }
            other => panic!("not an event: {other:?}"),
        }
        let bare = Outbound::parse(
            r#"{"type":"event","kind":"tool.result","output":{"id":"i","text":"t"}}"#,
        );
        assert!(
            matches!(&bare, Outbound::Event(e) if e.output.as_ref().is_some_and(|o| o.shown_lines == 20))
        );
        assert_eq!(
            Outbound::parse(
                r##"{"type":"view","kind":"context","turn":3,"turns":4,"text":"# Context","x":1}"##
            ),
            Outbound::View(View {
                kind: "context".into(),
                turn: Some(3),
                turns: 4,
                text: "# Context".into()
            })
        );
        assert!(matches!(
            Outbound::parse(r#"{"type":"view","kind":"context","turn":null,"turns":0,"text":""}"#),
            Outbound::View(View { turn: None, .. })
        ));
        assert_eq!(Outbound::parse(r#"{"type":"future"}"#), Outbound::Unknown);
        assert_eq!(
            Outbound::parse("plain text"),
            Outbound::Note {
                text: "plain text".into()
            }
        );
    }

    #[test]
    fn parses_a_notify_line_and_writes_hello() {
        assert_eq!(
            Outbound::parse(
                r#"{"type":"notify","title":"Build","subtitle":null,"body":"done","sound":false}"#
            ),
            Outbound::Notify(Notice {
                title: "Build".into(),
                subtitle: None,
                body: "done".into(),
                sound: false
            })
        );
        assert!(matches!(
            Outbound::parse(r#"{"type":"notify","body":"b","subtitle":"s"}"#),
            Outbound::Notify(Notice { subtitle: Some(s), .. }) if s == "s"
        ));
        let version = env!("CARGO_PKG_VERSION");
        assert_eq!(
            Inbound::hello(true).line(),
            format!(
                "{{\"type\":\"hello\",\"effects\":[\"approve\",\"approve-mcp\",\"keep-facts\",\"notify\"],\"client\":\"wisp-tui\",\"version\":\"{version}\"}}\n"
            )
        );
        assert!(
            Inbound::hello(false)
                .line()
                .contains("\"effects\":[\"approve\",\"approve-mcp\",\"keep-facts\"],")
        );
    }

    #[test]
    fn parses_a_fact_to_keep() {
        let line = r#"{"type":"approval","id":"mcp-a1b2c3d4","command":"release codename = BLUE HERON","line":"release codename = BLUE HERON","pattern":"","directory":"","level":"safe","reasons":[],"source":"mcp","thread":"git","client":"claude-code","request":"a1b2c3d4","kind":"fact","fact":{"id":"c3","subject":"entity","name":"release codename","value":"BLUE HERON","source":"model"}}"#;
        let Outbound::Approval(approval) = Outbound::parse(line) else {
            panic!("not an approval");
        };
        assert!(approval.is_mcp() && approval.is_fact());
        assert!(
            approval
                .fact
                .is_some_and(|fact| fact.id == "c3" && fact.value == "BLUE HERON")
        );
        // A command from the same server is not a fact.
        let Outbound::Approval(command) = Outbound::parse(
            r#"{"type":"approval","id":"mcp-1","command":"ls","line":"ls","pattern":"ls","directory":"/r","level":"safe","source":"mcp"}"#,
        ) else {
            panic!("not an approval");
        };
        assert!(!command.is_fact());
    }

    #[test]
    fn parses_an_mcp_approval_and_a_withdrawal() {
        let line = r#"{"type":"approval","id":"mcp-a1b2c3d4","command":"git push","line":"git push","pattern":"git push *","directory":"/r","level":"moderate","reasons":[],"source":"mcp","thread":"git","client":"claude-code","request":"a1b2c3d4"}"#;
        let Outbound::Approval(approval) = Outbound::parse(line) else {
            panic!("not an approval");
        };
        assert!(approval.is_mcp());
        assert_eq!(approval.thread.as_deref(), Some("git"));
        assert_eq!(approval.client.as_deref(), Some("claude-code"));
        assert_eq!(
            Outbound::parse(r#"{"type":"withdrawn","id":"mcp-a1b2c3d4"}"#),
            Outbound::Withdrawn {
                id: "mcp-a1b2c3d4".into()
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
