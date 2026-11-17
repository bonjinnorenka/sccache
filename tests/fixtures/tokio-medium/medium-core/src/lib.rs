use axum::{routing::get, Json, Router};
use serde::{Deserialize, Serialize};
use tracing_subscriber::EnvFilter;

#[derive(Debug, Serialize, Deserialize)]
pub struct HealthStatus {
    pub service: String,
    pub code: u16,
}

async fn health() -> Json<HealthStatus> {
    tracing::debug!("serving fixture health check");
    Json(HealthStatus {
        service: "tokio-medium".to_owned(),
        code: 200,
    })
}

pub fn build_router() -> Router {
    Router::new().route("/health", get(health))
}

pub fn describe_client_and_router() -> String {
    let _subscriber = tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::new("info"))
        .finish();
    let _client = reqwest::Client::builder()
        .no_proxy()
        .build()
        .expect("build reqwest client");
    let _router = build_router();
    let sample = HealthStatus {
        service: "tokio-medium".to_owned(),
        code: 200,
    };
    serde_json::to_string(&sample).expect("serialize sample status")
}
