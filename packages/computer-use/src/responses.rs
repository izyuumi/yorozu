//! Explicit-key Responses API transport. No credential discovery, retries or hosted tools.
use crate::model::*;
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::Deserialize;
use serde_json::{Value, json};
use std::time::Duration;

pub struct ResponsesModel {
    client: reqwest::Client,
    endpoint: reqwest::Url,
    key: String,
    model: String,
}
impl ResponsesModel {
    /// HTTPS provider endpoint, or numeric loopback HTTP for local fixture servers.
    /// The caller owns provider/key selection; neither environment nor keychain is read.
    pub fn new(endpoint: &str, key: String, model: String) -> Result<Self, String> {
        let endpoint = reqwest::Url::parse(endpoint).map_err(|_| "invalid provider URL")?;
        let loopback = endpoint.host_str().is_some_and(|s| {
            s.parse::<std::net::IpAddr>()
                .is_ok_and(|ip| ip.is_loopback())
        });
        if (endpoint.scheme() != "https" && !(endpoint.scheme() == "http" && loopback))
            || !endpoint.username().is_empty()
            || endpoint.password().is_some()
            || endpoint.query().is_some()
            || endpoint.fragment().is_some()
            || key.is_empty()
            || key.len() > 8192
            || key.contains(['\r', '\n'])
            || model.is_empty()
            || model.len() > 128
        {
            return Err("invalid provider configuration".into());
        }
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .no_proxy()
            .timeout(Duration::from_secs(30))
            .connect_timeout(Duration::from_secs(10))
            .build()
            .map_err(|_| "HTTP client unavailable")?;
        Ok(Self {
            client,
            endpoint,
            key,
            model,
        })
    }
}
impl OrdinaryModel for ResponsesModel {
    fn next<'a>(&'a mut self, request: ModelRequest<'a>) -> ModelFuture<'a> {
        Box::pin(async move {
            // Stateless bounded snapshot: receipts are untrusted context, not orphaned
            // function_call_output items (the original arguments are intentionally absent).
            let mut content = vec![
                json!({"type":"input_text", "text":serde_json::to_string(&json!({
                "goal":request.goal, "receipts":request.receipts()
            })).map_err(|_| "request encoding failed")?}),
            ];
            for image in request.images() {
                if image.mime_type != "image/png" {
                    return Err("unsupported image type".into());
                }
                content.push(json!({"type":"input_text", "text":format!("Observation {}", image.observation_id)}));
                content.push(json!({"type":"input_image", "image_url":format!("data:image/png;base64,{}", STANDARD.encode(image.png))}));
            }
            let body = json!({
                "model":self.model, "store":false, "stream":false,
                "instructions":format!("{} Return final text as JSON only: {{\"completed\":boolean,\"summary\":string}}.",request.instructions),
                "input":[{"role":"user","content":content}],
                "parallel_tool_calls":false, "max_output_tokens":4096,
                "tools":[{"type":"function","name":request.function.name,
                    "description":request.function.description,"parameters":request.function.parameters,"strict":false}]
            });
            let mut response = self
                .client
                .post(self.endpoint.clone())
                .bearer_auth(&self.key)
                .json(&body)
                .send()
                .await
                .map_err(|_| "provider transport failed")?;
            if !response.status().is_success() {
                return Err("provider HTTP failure; no retry".into());
            }
            let mut bytes = Vec::new();
            while let Some(chunk) = response.chunk().await.map_err(|_| "provider body failed")? {
                if bytes.len() + chunk.len() > 128 * 1024 {
                    return Err("provider response too large".into());
                }
                bytes.extend_from_slice(&chunk);
            }
            decode(&bytes)
        })
    }
}
fn decode(bytes: &[u8]) -> Result<ModelReply, String> {
    let value: Value = serde_json::from_slice(bytes).map_err(|_| "invalid provider JSON")?;
    if value["status"] != "completed" {
        return Err("provider response incomplete".into());
    }
    let output = value["output"]
        .as_array()
        .ok_or("missing provider output")?;
    let mut reply = None;
    for item in output {
        let next = match item["type"].as_str() {
            Some("reasoning") => continue,
            Some("function_call") => {
                let name = item["name"].as_str().ok_or("missing function name")?;
                let call_id = item["call_id"].as_str().ok_or("missing call ID")?;
                let arguments = item["arguments"].as_str().ok_or("missing arguments")?;
                if name != FUNCTION_NAME {
                    return Err("unsupported provider tool".into());
                }
                crate::executor::valid_id(call_id)?;
                ModelBatch::decode(arguments.as_bytes())?;
                ModelReply::FunctionCall(FunctionCall {
                    name: name.into(),
                    call_id: call_id.into(),
                    arguments_json: arguments.as_bytes().to_vec(),
                })
            }
            Some("message") => {
                if item["role"] != "assistant" {
                    return Err("invalid message role".into());
                }
                let content = item["content"]
                    .as_array()
                    .ok_or("missing message content")?;
                if content.len() != 1 || content[0]["type"] != "output_text" {
                    return Err("unsupported provider content".into());
                }
                #[derive(Deserialize)]
                #[serde(deny_unknown_fields)]
                struct Finish {
                    completed: bool,
                    summary: String,
                }
                let finish: Finish =
                    serde_json::from_str(content[0]["text"].as_str().ok_or("missing final text")?)
                        .map_err(|_| "invalid final outcome")?;
                if finish.summary.is_empty() || finish.summary.len() > 2048 {
                    return Err("invalid final summary".into());
                }
                ModelReply::Finish {
                    completed: finish.completed,
                    summary: finish.summary,
                }
            }
            _ => return Err("unsupported provider output".into()),
        };
        if reply.replace(next).is_some() {
            return Err("multiple provider actions rejected".into());
        }
    }
    reply.ok_or("empty provider reply".into())
}
