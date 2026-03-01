import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";

const errorRate = new Rate("errors");
const flagsLatency = new Trend("flags_latency", true);
const identitiesLatency = new Trend("identities_latency", true);

const BASE_URL = `http://${__ENV.EDGE_HOST || "localhost"}:${__ENV.EDGE_PORT || "18000"}`;
const ENV_KEY = __ENV.ENV_KEY || "";

export const options = {
  scenarios: {
    ramp_up: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "10s", target: 50 },
        { duration: "40s", target: 50 },
        { duration: "10s", target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<500", "p(99)<1000"],
    errors: ["rate<0.01"],
  },
};

const headers = {
  "X-Environment-Key": ENV_KEY,
  Accept: "application/json",
};

export default function () {
  // GET /api/v1/flags/
  const flagsRes = http.get(`${BASE_URL}/api/v1/flags/`, { headers });
  flagsLatency.add(flagsRes.timings.duration);

  const flagsOk = check(flagsRes, {
    "flags: status 200": (r) => r.status === 200,
    "flags: contains feature data": (r) => r.body.includes("feature"),
  });
  errorRate.add(!flagsOk);

  // GET /api/v1/identities/?identifier=user-{vu}-{iter}
  const identifier = `user-${__VU}-${__ITER}`;
  const identitiesRes = http.get(
    `${BASE_URL}/api/v1/identities/?identifier=${identifier}`,
    { headers },
  );
  identitiesLatency.add(identitiesRes.timings.duration);

  const identitiesOk = check(identitiesRes, {
    "identities: status 200": (r) => r.status === 200,
  });
  errorRate.add(!identitiesOk);

  sleep(0.1);
}
