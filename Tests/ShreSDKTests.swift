import XCTest
@testable import ShreAI

// MARK: - Mock URLSession

class MockURLSession: URLSession {
  var data: Data?
  var response: HTTPURLResponse?
  var error: Error?
  var capturedRequest: URLRequest?

  override func dataTask(with request: URLRequest, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
    capturedRequest = request
    return MockURLSessionDataTask {
      completionHandler(self.data, self.response, self.error)
    }
  }
}

class MockURLSessionDataTask: URLSessionDataTask {
  let closure: () -> Void

  init(closure: @escaping () -> Void) {
    self.closure = closure
  }

  override func resume() {
    closure()
  }
}

// MARK: - Test Cases

final class ShreSDKTests: XCTestCase {

  var sdk: ShreSDK!
  var mockSession: MockURLSession!

  override func setUp() {
    super.setUp()
    sdk = ShreSDK(
      tenantId: "test-tenant-123",
      platform: "ios",
      baseURL: URL(string: "https://api.shre.test")!
    )
    mockSession = MockURLSession()
  }

  override func tearDown() {
    sdk = nil
    mockSession = nil
    super.tearDown()
  }

  // MARK: - Helper Methods

  private func setMockResponse(
    data: Data? = nil,
    statusCode: Int = 200,
    error: Error? = nil
  ) {
    if let data = data {
      mockSession.data = data
    }
    mockSession.response = HTTPURLResponse(
      url: URL(string: "https://api.shre.test")!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
    )
    mockSession.error = error
  }

  private func createJSONData(from dictionary: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: dictionary)
  }

  // MARK: - POST /v1/events/batch Tests

  func testEventsBatchSuccess() {
    let expectation = XCTestExpectation(description: "events batch succeeds")

    let mockResponse: [String: Any] = [
      "accepted": 5,
      "rejected": 0,
      "trackingEnabled": true,
      "nextFlushSeconds": 60
    ]
    setMockResponse(data: createJSONData(from: mockResponse))

    let events = [
      Event(
        eventId: "evt-001",
        eventName: "item_sold",
        entityType: "item",
        entityId: "UPC_123456",
        metadata: ["quantity": 2, "price": 10.99]
      ),
      Event(
        eventId: "evt-002",
        eventName: "payment_processed",
        entityType: "transaction",
        metadata: ["method": "card"]
      )
    ]

    sdk.sendEventsBatch(events: events) { result in
      switch result {
      case .success(let response):
        XCTAssertEqual(response.accepted, 5)
        XCTAssertEqual(response.rejected, 0)
        XCTAssertTrue(response.trackingEnabled)
        XCTAssertEqual(response.nextFlushSeconds, 60)
        expectation.fulfill()
      case .failure:
        XCTFail("Expected success")
      }
    }

    wait(for: [expectation], timeout: 1.0)

    XCTAssertNotNil(mockSession.capturedRequest)
    XCTAssertEqual(mockSession.capturedRequest?.httpMethod, "POST")
    XCTAssertEqual(mockSession.capturedRequest?.url?.path, "/v1/events/batch")
    XCTAssertEqual(mockSession.capturedRequest?.value(forHTTPHeaderField: "x-shre-tenant"), "test-tenant-123")
    XCTAssertEqual(mockSession.capturedRequest?.value(forHTTPHeaderField: "x-shre-app"), "ios")
  }

  func testEventsBatchHeadersValidation() {
    let expectation = XCTestExpectation(description: "event batch sends correct headers")
    setMockResponse(data: createJSONData(from: ["accepted": 1, "rejected": 0, "trackingEnabled": true, "nextFlushSeconds": 60]))

    let events = [Event(eventId: "evt-001", eventName: "test", entityType: "test")]

    sdk.sendEventsBatch(events: events) { _ in
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 1.0)

    XCTAssertEqual(mockSession.capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(mockSession.capturedRequest?.value(forHTTPHeaderField: "x-shre-tenant"), "test-tenant-123")
    XCTAssertEqual(mockSession.capturedRequest?.value(forHTTPHeaderField: "x-shre-app"), "ios")
  }

  func testEventsBatchBadRequest() {
    let expectation = XCTestExpectation(description: "events batch handles 400")
    setMockResponse(statusCode: 400)

    let events = [Event(eventId: "evt-001", eventName: "test", entityType: "test")]

    sdk.sendEventsBatch(events: events) { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        if case .badRequest = error {
          expectation.fulfill()
        } else {
          XCTFail("Expected badRequest error, got \(error)")
        }
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testEventsBatchUnauthorized() {
    let expectation = XCTestExpectation(description: "events batch handles 401")
    setMockResponse(statusCode: 401)

    let events = [Event(eventId: "evt-001", eventName: "test", entityType: "test")]

    sdk.sendEventsBatch(events: events) { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        if case .unauthorized = error {
          expectation.fulfill()
        } else {
          XCTFail("Expected unauthorized error, got \(error)")
        }
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testEventsBatchServerError() {
    let expectation = XCTestExpectation(description: "events batch handles 500")
    setMockResponse(statusCode: 500)

    let events = [Event(eventId: "evt-001", eventName: "test", entityType: "test")]

    sdk.sendEventsBatch(events: events) { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        if case .serverError(let code) = error, code == 500 {
          expectation.fulfill()
        } else {
          XCTFail("Expected serverError(500), got \(error)")
        }
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testEventsBatchNetworkError() {
    let expectation = XCTestExpectation(description: "events batch handles network error")
    let networkError = NSError(domain: "network", code: -1)
    setMockResponse(error: networkError)

    let events = [Event(eventId: "evt-001", eventName: "test", entityType: "test")]

    sdk.sendEventsBatch(events: events) { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        if case .networkError = error {
          expectation.fulfill()
        } else {
          XCTFail("Expected networkError, got \(error)")
        }
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testEventsBatchDecodingError() {
    let expectation = XCTestExpectation(description: "events batch handles decoding error")
    mockSession.data = "invalid json".data(using: .utf8)
    mockSession.response = HTTPURLResponse(
      url: URL(string: "https://api.shre.test")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )

    let events = [Event(eventId: "evt-001", eventName: "test", entityType: "test")]

    sdk.sendEventsBatch(events: events) { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        if case .decodingError = error {
          expectation.fulfill()
        } else {
          XCTFail("Expected decodingError, got \(error)")
        }
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testEventsSerialization() {
    let event = Event(
      eventId: "evt-123",
      eventName: "price_changed",
      entityType: "item",
      entityId: "UPC_001",
      timestamp: Date(timeIntervalSince1970: 0),
      metadata: ["old": 9.99, "new": 10.99]
    )

    let dict = event.dictionary
    XCTAssertEqual(dict["eventId"] as? String, "evt-123")
    XCTAssertEqual(dict["eventName"] as? String, "price_changed")
    XCTAssertEqual(dict["entityType"] as? String, "item")
    XCTAssertEqual(dict["entityId"] as? String, "UPC_001")
    XCTAssertNotNil(dict["timestamp"])
    XCTAssertNotNil(dict["metadata"])
  }

  // MARK: - POST /v1/sdk/session Tests

  func testCreateSessionSuccess() {
    let expectation = XCTestExpectation(description: "session creation succeeds")

    let mockResponse: [String: Any] = [
      "accessToken": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
      "expiresIn": 3600,
      "tokenType": "Bearer"
    ]
    setMockResponse(data: createJSONData(from: mockResponse))

    sdk.createSession(bootstrapKey: "bootstrap-key-123") { result in
      switch result {
      case .success(let response):
        XCTAssertEqual(response.accessToken, "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...")
        XCTAssertEqual(response.expiresIn, 3600)
        XCTAssertEqual(response.tokenType, "Bearer")
        expectation.fulfill()
      case .failure:
        XCTFail("Expected success")
      }
    }

    wait(for: [expectation], timeout: 1.0)

    XCTAssertNotNil(mockSession.capturedRequest)
    XCTAssertEqual(mockSession.capturedRequest?.httpMethod, "POST")
    XCTAssertEqual(mockSession.capturedRequest?.url?.path, "/v1/sdk/session")
  }

  func testCreateSessionHeadersValidation() {
    let expectation = XCTestExpectation(description: "session request sends correct headers")
    setMockResponse(data: createJSONData(from: ["accessToken": "token", "expiresIn": 3600, "tokenType": "Bearer"]))

    sdk.createSession(bootstrapKey: "bootstrap-key-123") { _ in
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 1.0)

    XCTAssertEqual(mockSession.capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(mockSession.capturedRequest?.value(forHTTPHeaderField: "x-shre-tenant"), "test-tenant-123")
    XCTAssertEqual(mockSession.capturedRequest?.value(forHTTPHeaderField: "x-shre-app"), "bootstrap-key-123")
  }

  func testCreateSessionUnauthorized() {
    let expectation = XCTestExpectation(description: "session creation handles 401")
    setMockResponse(statusCode: 401)

    sdk.createSession(bootstrapKey: "invalid-key") { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        if case .unauthorized = error {
          expectation.fulfill()
        } else {
          XCTFail("Expected unauthorized error")
        }
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testCreateSessionBadRequest() {
    let expectation = XCTestExpectation(description: "session creation handles 400")
    setMockResponse(statusCode: 400)

    sdk.createSession(bootstrapKey: "") { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        if case .badRequest = error {
          expectation.fulfill()
        } else {
          XCTFail("Expected badRequest error")
        }
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testCreateSessionServerError() {
    let expectation = XCTestExpectation(description: "session creation handles 500")
    setMockResponse(statusCode: 503)

    sdk.createSession(bootstrapKey: "key") { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        if case .serverError(let code) = error, code == 503 {
          expectation.fulfill()
        } else {
          XCTFail("Expected serverError")
        }
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testCreateSessionStoresToken() {
    let expectation = XCTestExpectation(description: "session stores auth token")
    let mockResponse: [String: Any] = [
      "accessToken": "stored-token-xyz",
      "expiresIn": 3600,
      "tokenType": "Bearer"
    ]
    setMockResponse(data: createJSONData(from: mockResponse))

    sdk.createSession(bootstrapKey: "key") { result in
      switch result {
      case .success:
        expectation.fulfill()
      case .failure:
        XCTFail("Expected success")
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testCreateSessionDecodingError() {
    let expectation = XCTestExpectation(description: "session handles decoding error")
    mockSession.data = "malformed".data(using: .utf8)
    mockSession.response = HTTPURLResponse(
      url: URL(string: "https://api.shre.test")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )

    sdk.createSession(bootstrapKey: "key") { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        if case .decodingError = error {
          expectation.fulfill()
        } else {
          XCTFail("Expected decodingError")
        }
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  // MARK: - GET /v1/sdk/config Tests

  func testGetConfigSuccess() {
    let expectation = XCTestExpectation(description: "config fetch succeeds")

    let mockResponse: [String: Any] = [
      "trackingEnabled": true,
      "disabledEvents": ["internal_event"],
      "piiMasking": false,
      "maxQueueSize": 1000,
      "flushIntervalSeconds": 60,
      "batchSize": 100,
      "sinkConfigured": true
    ]
    setMockResponse(data: createJSONData(from: mockResponse))

    sdk.getConfig { result in
      switch result {
      case .success(let response):
        XCTAssertTrue(response.trackingEnabled)
        XCTAssertEqual(response.disabledEvents.count, 1)
        XCTAssertFalse(response.piiMasking)
        XCTAssertEqual(response.maxQueueSize, 1000)
        XCTAssertEqual(response.flushIntervalSeconds, 60)
        XCTAssertEqual(response.batchSize, 100)
        XCTAssertTrue(response.sinkConfigured)
        expectation.fulfill()
      case .failure:
        XCTFail("Expected success")
      }
    }

    wait(for: [expectation], timeout: 1.0)

    XCTAssertNotNil(mockSession.capturedRequest)
    XCTAssertEqual(mockSession.capturedRequest?.httpMethod, "GET")
    XCTAssertEqual(mockSession.capturedRequest?.url?.path, "/v1/sdk/config")
  }

  func testGetConfigHeadersValidation() {
    let expectation = XCTestExpectation(description: "config request sends correct headers")
    let mockResponse: [String: Any] = [
      "trackingEnabled": true,
      "disabledEvents": [],
      "piiMasking": false,
      "maxQueueSize": 1000,
      "flushIntervalSeconds": 60,
      "batchSize": 100,
      "sinkConfigured": true
    ]
    setMockResponse(data: createJSONData(from: mockResponse))

    sdk.getConfig { _ in
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 1.0)

    XCTAssertEqual(mockSession.capturedRequest?.value(forHTTPHeaderField: "x-shre-tenant"), "test-tenant-123")
    XCTAssertNil(mockSession.capturedRequest?.value(forHTTPHeaderField: "x-shre-app"))
  }

  func testGetConfigNotFound() {
    let expectation = XCTestExpectation(description: "config handles 404")
    setMockResponse(statusCode: 404)

    sdk.getConfig { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        if case .unknownError(let code) = error, code == 404 {
          expectation.fulfill()
        } else {
          XCTFail("Expected unknownError(404)")
        }
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testGetConfigServerError() {
    let expectation = XCTestExpectation(description: "config handles server error")
    setMockResponse(statusCode: 502)

    sdk.getConfig { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        if case .serverError(let code) = error, code == 502 {
          expectation.fulfill()
        } else {
          XCTFail("Expected serverError(502)")
        }
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testGetConfigDecodingError() {
    let expectation = XCTestExpectation(description: "config handles decoding error")
    mockSession.data = "{}".data(using: .utf8)
    mockSession.response = HTTPURLResponse(
      url: URL(string: "https://api.shre.test")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )

    sdk.getConfig { result in
      switch result {
      case .success:
        XCTFail("Expected failure due to missing fields")
      case .failure(let error):
        if case .decodingError = error {
          expectation.fulfill()
        } else {
          XCTFail("Expected decodingError")
        }
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  // MARK: - POST /v1/sdk/heartbeat Tests

  func testHeartbeatSuccess() {
    let expectation = XCTestExpectation(description: "heartbeat succeeds")

    let mockResponse: [String: Any] = [
      "ok": true,
      "serverTime": "2026-05-02T12:00:00Z"
    ]
    setMockResponse(data: createJSONData(from: mockResponse))

    sdk.sendHeartbeat(
      deviceId: "device-001",
      eventsQueued: 5,
      eventsSent: 10
    ) { result in
      switch result {
      case .success(let response):
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.serverTime, "2026-05-02T12:00:00Z")
        expectation.fulfill()
      case .failure:
        XCTFail("Expected success")
      }
    }

    wait(for: [expectation], timeout: 1.0)

    XCTAssertNotNil(mockSession.capturedRequest)
    XCTAssertEqual(mockSession.capturedRequest?.httpMethod, "POST")
    XCTAssertEqual(mockSession.capturedRequest?.url?.path, "/v1/sdk/heartbeat")
  }

  func testHeartbeatHeadersValidation() {
    let expectation = XCTestExpectation(description: "heartbeat sends correct headers")
    let mockResponse: [String: Any] = ["ok": true, "serverTime": "2026-05-02T12:00:00Z"]
    setMockResponse(data: createJSONData(from: mockResponse))

    sdk.sendHeartbeat(deviceId: "device-001", eventsQueued: 5) { _ in
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 1.0)

    XCTAssertEqual(mockSession.capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(mockSession.capturedRequest?.value(forHTTPHeaderField: "x-shre-tenant"), "test-tenant-123")
    XCTAssertEqual(mockSession.capturedRequest?.value(forHTTPHeaderField: "x-shre-app"), "ios")
  }

  func testHeartbeatBadRequest() {
    let expectation = XCTestExpectation(description: "heartbeat handles 400")
    setMockResponse(statusCode: 400)

    sdk.sendHeartbeat(deviceId: "", eventsQueued: -1) { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        if case .badRequest = error {
          expectation.fulfill()
        } else {
          XCTFail("Expected badRequest")
        }
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testHeartbeatServerError() {
    let expectation = XCTestExpectation(description: "heartbeat handles server error")
    setMockResponse(statusCode: 500)

    sdk.sendHeartbeat(deviceId: "device-001", eventsQueued: 5) { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        if case .serverError(let code) = error, code == 500 {
          expectation.fulfill()
        } else {
          XCTFail("Expected serverError(500)")
        }
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testHeartbeatNetworkError() {
    let expectation = XCTestExpectation(description: "heartbeat handles network error")
    let networkError = NSError(domain: "network", code: -1009)
    setMockResponse(error: networkError)

    sdk.sendHeartbeat(deviceId: "device-001", eventsQueued: 5) { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        if case .networkError = error {
          expectation.fulfill()
        } else {
          XCTFail("Expected networkError")
        }
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testHeartbeatDecodingError() {
    let expectation = XCTestExpectation(description: "heartbeat handles decoding error")
    mockSession.data = "invalid".data(using: .utf8)
    mockSession.response = HTTPURLResponse(
      url: URL(string: "https://api.shre.test")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )

    sdk.sendHeartbeat(deviceId: "device-001", eventsQueued: 5) { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        if case .decodingError = error {
          expectation.fulfill()
        } else {
          XCTFail("Expected decodingError")
        }
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testHeartbeatPayload() {
    let expectation = XCTestExpectation(description: "heartbeat sends correct payload")
    let mockResponse: [String: Any] = ["ok": true, "serverTime": "2026-05-02T12:00:00Z"]
    setMockResponse(data: createJSONData(from: mockResponse))

    sdk.sendHeartbeat(
      deviceId: "device-xyz",
      eventsQueued: 42,
      eventsSent: 100
    ) { _ in
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 1.0)

    guard let requestBody = mockSession.capturedRequest?.httpBody else {
      XCTFail("No request body")
      return
    }

    let payload = try! JSONSerialization.jsonObject(with: requestBody) as! [String: Any]
    XCTAssertEqual(payload["deviceId"] as? String, "device-xyz")
    XCTAssertEqual(payload["eventsQueued"] as? Int, 42)
    XCTAssertEqual(payload["eventsSent"] as? Int, 100)
  }

  // MARK: - Integration Tests

  func testMultipleEndpointsConcurrently() {
    let expectation1 = XCTestExpectation(description: "events batch completes")
    let expectation2 = XCTestExpectation(description: "config fetch completes")
    let expectation3 = XCTestExpectation(description: "heartbeat completes")

    let mockResponse: [String: Any] = ["accepted": 1, "rejected": 0, "trackingEnabled": true, "nextFlushSeconds": 60]
    setMockResponse(data: createJSONData(from: mockResponse))

    let events = [Event(eventId: "evt-001", eventName: "test", entityType: "test")]
    sdk.sendEventsBatch(events: events) { _ in
      expectation1.fulfill()
    }

    let mockConfigResponse: [String: Any] = [
      "trackingEnabled": true,
      "disabledEvents": [],
      "piiMasking": false,
      "maxQueueSize": 1000,
      "flushIntervalSeconds": 60,
      "batchSize": 100,
      "sinkConfigured": true
    ]
    setMockResponse(data: createJSONData(from: mockConfigResponse))
    sdk.getConfig { _ in
      expectation2.fulfill()
    }

    let mockHeartbeatResponse: [String: Any] = ["ok": true, "serverTime": "2026-05-02T12:00:00Z"]
    setMockResponse(data: createJSONData(from: mockHeartbeatResponse))
    sdk.sendHeartbeat(deviceId: "device-001", eventsQueued: 0) { _ in
      expectation3.fulfill()
    }

    wait(for: [expectation1, expectation2, expectation3], timeout: 3.0)
  }

  func testErrorResponsesConsistency() {
    let errors: [(Int, ShreError)] = [
      (400, .badRequest),
      (401, .unauthorized),
      (500, .serverError(500)),
      (503, .serverError(503))
    ]

    for (statusCode, expectedError) in errors {
      let expectation = XCTestExpectation(description: "handles status code \(statusCode)")
      setMockResponse(statusCode: statusCode)

      let events = [Event(eventId: "evt-001", eventName: "test", entityType: "test")]
      sdk.sendEventsBatch(events: events) { result in
        switch result {
        case .success:
          XCTFail("Expected error for status \(statusCode)")
        case .failure(let error):
          let errorDescription = String(describing: error)
          let expectedDescription = String(describing: expectedError)
          XCTAssertEqual(errorDescription, expectedDescription, "Mismatch for status \(statusCode)")
          expectation.fulfill()
        }
      }

      wait(for: [expectation], timeout: 1.0)
    }
  }
}
