use serde_json::{Value, json};
use std::collections::VecDeque;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};
use yorozu_computer_use::{contract::*, model::*, responses::ResponsesModel};

// Real HTTP boundary: protects image encoding, auth routing, single-call decoding,
// refusal/error handling and no retry. Existing inert-model tests cannot reach HTTP.
#[tokio::test]
async fn local_http_contract() {
    let call = json!({"type":"function_call","name":FUNCTION_NAME,"call_id":"call-1","arguments":"{\"deadline_ms\":1000,\"actions\":[{\"action\":\"screenshot\"}]}"});
    let finish = json!({"type":"message","role":"assistant","content":[{"type":"output_text","text":"{\"completed\":false,\"summary\":\"fixture stuck\"}"}]});
    for (status, output, kind) in [
        (200, json!([call.clone()]), "call"),
        (200, json!([finish]), "finish"),
        (200, json!([call.clone(), call]), "error"),
        (200, json!([{"type":"computer_call"}]), "error"),
        (
            200,
            json!([{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"no"}]}]),
            "error",
        ),
        (429, json!([]), "error"),
        (302, json!([]), "error"),
    ] {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("http://{}/v1/responses", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut bytes = Vec::new();
            let header_end = loop {
                let mut b = [0; 1024];
                let n = socket.read(&mut b).await.unwrap();
                assert!(n > 0);
                bytes.extend_from_slice(&b[..n]);
                if let Some(i) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                    break i + 4;
                }
            };
            let header = String::from_utf8(bytes[..header_end].to_vec()).unwrap();
            assert!(header.starts_with("POST /v1/responses HTTP/1.1"));
            assert!(
                header
                    .to_lowercase()
                    .contains("authorization: bearer synthetic-key")
            );
            let length: usize = header
                .lines()
                .find_map(|l| {
                    l.to_lowercase()
                        .strip_prefix("content-length: ")
                        .map(|s| s.parse().unwrap())
                })
                .unwrap();
            while bytes.len() < header_end + length {
                let mut b = [0; 4096];
                let n = socket.read(&mut b).await.unwrap();
                assert!(n > 0);
                bytes.extend_from_slice(&b[..n]);
            }
            let body: Value =
                serde_json::from_slice(&bytes[header_end..header_end + length]).unwrap();
            assert_eq!(body["store"], false);
            assert_eq!(body["parallel_tool_calls"], false);
            assert_eq!(body["tools"].as_array().unwrap().len(), 1);
            assert_eq!(body["tools"][0]["name"], FUNCTION_NAME);
            assert_eq!(
                body["input"][0]["content"][2]["image_url"],
                "data:image/png;base64,AQID"
            );
            assert!(
                body["input"][0]["content"][0]["text"]
                    .as_str()
                    .unwrap()
                    .contains("observation-1")
            );
            let response = json!({"status":"completed","output":output}).to_string();
            socket.write_all(format!("HTTP/1.1 {status} Fixture\r\nContent-Length: {}\r\nConnection: close\r\nLocation: http://127.0.0.1:1/forbidden\r\n\r\n{response}",response.len()).as_bytes()).await.unwrap();
        });
        let ids = TaskIds {
            task_id: "t".into(),
            parent_id: "p".into(),
            origin_id: "o".into(),
            attempt_id: "a".into(),
        };
        let goal = WorkerGoal {
            ids: ids.clone(),
            goal: "fixture".into(),
            context: String::new(),
            authorization: "synthetic".into(),
        };
        let rect = Rect {
            x: 0.,
            y: 0.,
            width: 10.,
            height: 10.,
        };
        let history = VecDeque::from([BatchResult {
            ids,
            batch_id: "prior".into(),
            input_halted: false,
            rejection: None,
            results: vec![ActionResult {
                index: 0,
                status: ActionStatus::Completed,
                detail: String::new(),
                observation: Some(Observation {
                    observation_id: "observation-1".into(),
                    mime_type: "image/png".into(),
                    image: vec![1, 2, 3],
                    transform: DisplayTransform {
                        display_id: 1,
                        window_id: 1,
                        display_frame: rect,
                        window_frame: rect,
                        pixel_width: 10,
                        pixel_height: 10,
                    },
                }),
            }],
        }]);
        let function = desktop_function();
        let mut provider =
            ResponsesModel::new(&endpoint, "synthetic-key".into(), "fixture-model".into()).unwrap();
        let reply = provider
            .next(ModelRequest {
                goal: &goal,
                history: &history,
                function: &function,
                instructions: WORKER_INSTRUCTIONS,
            })
            .await;
        match kind {
            "call" => assert!(
                matches!(reply,Ok(ModelReply::FunctionCall(FunctionCall{call_id,..})) if call_id=="call-1")
            ),
            "finish" => assert!(
                matches!(reply,Ok(ModelReply::Finish{completed:false,summary}) if summary=="fixture stuck")
            ),
            _ => assert!(reply.is_err()),
        }
        server.await.unwrap();
    }
}
