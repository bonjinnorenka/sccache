use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
pub struct Payload {
    pub label: String,
    pub value: u64,
}

pub async fn render_async(input: u64) -> String {
    let payload = Payload {
        label: "tokio-small".to_owned(),
        value: input * 3 + 7,
    };
    serde_json::to_string(&payload).expect("serialize payload")
}

pub fn compute(input: u64) -> String {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("build current-thread runtime");
    rt.block_on(render_async(input))
}
