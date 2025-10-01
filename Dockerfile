package main.java.com.automation.kubevirt;

import com.fasterxml.jackson.databind.JsonNode;

/** Decides restart by comparing user-requested values vs desired VM spec, and checks RestartRequired condition. */
public class VmRestartPlanner {

    public static class Result {
        public final boolean desiredMatchesUser;
        public final boolean restartRequired;
        public Result(boolean desiredMatchesUser, boolean restartRequired) {
            this.desiredMatchesUser = desiredMatchesUser;
            this.restartRequired = restartRequired;
        }
    }

    /** return desiredMatchesUser + restartRequired flags (no VMI involved) */
    public Result evaluate(JsonNode vm, int userVcpu, String userMemQty) {
        int desiredVcpu = extractVcpuFromVM(vm);
        long desiredMemMi = extractMemMiFromVM(vm);
        long userMemMi = parseQtyMi(userMemQty);

        boolean matches = (desiredVcpu == userVcpu) && (desiredMemMi == userMemMi);
        boolean restartNeeded = hasRestartRequiredTrue(vm);

        return new Result(matches, restartNeeded);
    }

    /** true if VM.status.conditions has {type: "RestartRequired", status: "True"} */
    public boolean hasRestartRequiredTrue(JsonNode vm) {
        JsonNode conditions = vm.at("/status/conditions");
        if (!conditions.isArray()) return false;
        for (JsonNode c : conditions) {
            String type = c.path("type").asText("");
            String status = c.path("status").asText("");
            if ("RestartRequired".equals(type) && "True".equalsIgnoreCase(status)) return true;
        }
        return false;
    }

    // ---- desired (VM.spec) extractors ----
    private int extractVcpuFromVM(JsonNode vm) {
        JsonNode cpu = vm.at("/spec/template/spec/domain/cpu");
        if (cpu.isMissingNode()) return 0;
        int sockets = optInt(cpu.get("sockets"), 1);
        int cores   = optInt(cpu.get("cores"), 1);
        int threads = optInt(cpu.get("threads"), 1);
        return sockets * cores * threads;
    }

    private long extractMemMiFromVM(JsonNode vm) {
        // prefer resources.requests.memory, else domain.memory.guest
        String mem = null;
        var reqMem = vm.at("/spec/template/spec/domain/resources/requests/memory");
        if (!reqMem.isMissingNode()) mem = reqMem.asText();
        if (mem == null || mem.isBlank()) {
            var guest = vm.at("/spec/template/spec/domain/memory/guest");
            if (!guest.isMissingNode()) mem = guest.asText();
        }
        return parseQtyMi(mem);
    }

    // ---- utils ----
    private int optInt(JsonNode n, int d) { return (n == null || n.isMissingNode()) ? d : n.asInt(d); }

    /** Parse k8s quantity to Mi (supports Ki, Mi, Gi). */
    private long parseQtyMi(String q) {
        if (q == null || q.isBlank()) return 0;
        q = q.trim().toUpperCase();
        try {
            if (q.endsWith("GI")) return Math.round(Double.parseDouble(q.replace("GI","").trim()) * 1024);
            if (q.endsWith("MI")) return Math.round(Double.parseDouble(q.replace("MI","").trim()));
            if (q.endsWith("KI")) return Math.round(Double.parseDouble(q.replace("KI","").trim()) / 1024);
            // bare number → assume Mi for lab simplicity
            return Math.round(Double.parseDouble(q));
        } catch (Exception e) {
            return 0;
        }
    }
}



-------------------------

package main.java.com.automation.kubevirt.runner;

import com.fasterxml.jackson.databind.JsonNode;
import main.java.com.automation.kubevirt.KubevirtApiService;
import main.java.com.automation.kubevirt.VmRestartPlanner;
import org.springframework.boot.CommandLineRunner;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Component;

@Component
@Profile("resize-check")
public class ResizeCheckRunner implements CommandLineRunner {

    // ---- hardcode for demo (replace for your env) ----
    private static final String API_SERVER = "https://api.wh-ngcpntt1.svr.us.jpmchase.net:6443";
    private static final String TOKEN      = "eyJhbGciOi...<paste lab token>...";
    private static final String NS         = "icpwforge";
    private static final String VM_NAME    = "vmh02";

    // ---- user-requested values (simulate request payload) ----
    private static final int    REQ_VCPU   = 8;     // e.g., sockets*cores*threads total
    private static final String REQ_MEMORY = "6Gi"; // k8s quantity string

    @Override
    public void run(String... args) throws Exception {
        System.out.println("=== ResizeCheckRunner (user-input vs desired + RestartRequired) ===");

        var api = new KubevirtApiService(API_SERVER, TOKEN);
        JsonNode vm = api.getVM(NS, VM_NAME);

        var planner = new VmRestartPlanner();
        var result  = planner.evaluate(vm, REQ_VCPU, REQ_MEMORY);

        // Some prints to help your demo
        System.out.println("[User Input] vCPU=" + REQ_VCPU + ", Mem=" + REQ_MEMORY);
        System.out.println("[Desired.vm.spec.domain.cpu]   = " + vm.at("/spec/template/spec/domain/cpu").toString());
        System.out.println("[Desired.requests.memory]      = " + vm.at("/spec/template/spec/domain/resources/requests/memory").asText(null));
        System.out.println("[VM.status.conditions]         = " + vm.at("/status/conditions").toString());

        if (!result.desiredMatchesUser) {
            System.out.println("[SKIP] Desired spec != user input. Likely ArgoCD hasn’t applied yet. Not restarting.");
            return;
        }

        if (result.restartRequired) {
            System.out.println("[ACTION] Desired equals user input AND RestartRequired=True → posting restart...");
            int code = api.restartVM(NS, VM_NAME);
            System.out.println("[RESULT] restart HTTP status: " + code + (code/100==2 ? " (OK)" : " (check errors)"));
        } else {
            System.out.println("[OK] Desired equals user input but RestartRequired is not True → no restart.");
        }

        System.out.println("=== Done ===");
    }
}


--------------------------------------
------------------------------------

package main.java.com.automation.fileuploader.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import javax.net.ssl.*;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.security.KeyManagementException;
import java.security.NoSuchAlgorithmException;
import java.time.Duration;

public class ResourceService {

    // e.g. https://api.wh-ngcpntt1.svr.us.jpmchase.net:6443
    private final String baseUrl;
    // Bearer <token>
    private final String token;
    private final HttpClient http;
    private final ObjectMapper om = new ObjectMapper();

    public ResourceService(String baseUrl, String token) {
        this.baseUrl = baseUrl.endsWith("/") ? baseUrl.substring(0, baseUrl.length() - 1) : baseUrl;
        this.token = token;
        this.http = trustAllHttpClient();   // keep your -k style client
    }

    // ---------------- public API ----------------

    /** GET /apis/kubevirt.io/v1/namespaces/{ns}/virtualmachines/{vm} */
    public JsonNode getVM(String ns, String vmName) throws Exception {
        var url = baseUrl + "/apis/kubevirt.io/v1/namespaces/" + ns + "/virtualmachines/" + vmName;
        return getJson(url);
    }

    /**
     * GET /apis/kubevirt.io/v1/namespaces/{ns}/virtualmachineinstances/{vm}
     * Returns null if VMI doesn't exist (VM not running).
     */
    public JsonNode getVMI(String ns, String vmName) throws Exception {
        var url = baseUrl + "/apis/kubevirt.io/v1/namespaces/" + ns + "/virtualmachineinstances/" + vmName;
        return getJsonOrNull(url);
    }

    /**
     * POST /apis/subresources.kubevirt.io/v1/namespaces/{ns}/virtualmachines/{vm}/restart
     * Returns HTTP status code.
     */
    public int restartVM(String ns, String vmName) throws Exception {
        var url = baseUrl + "/apis/subresources.kubevirt.io/v1/namespaces/" + ns + "/virtualmachines/" + vmName + "/restart";

        var req = baseRequest(url)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString("{}"))   // <-- required empty JSON body
            .build();

        var res = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() / 100 != 2) {
            // Bubble up useful diagnostics (403 RBAC, 404 path, 409 state, 415/406 headers, etc.)
            throw new IOException("Restart failed: HTTP " + res.statusCode()
                + " -- " + safeK8sStatus(res.body()) + " (url=" + url + ")");
        }
        return res.statusCode();
    }

    // ---------------- helpers ----------------

    private JsonNode getJson(String url) throws Exception {
        var req = baseRequest(url).GET().build();
        var res = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() / 100 != 2) {
            throw new IOException("GET failed: HTTP " + res.statusCode()
                + " (url=" + url + ") -- " + safeK8sStatus(res.body()));
        }
        return om.readTree(res.body());
    }

    /** GET that returns null on 404 (useful for VMI not running). */
    private JsonNode getJsonOrNull(String url) throws Exception {
        var req = baseRequest(url).GET().build();
        var res = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() == 404) return null;
        if (res.statusCode() / 100 != 2) {
            throw new IOException("GET failed: HTTP " + res.statusCode()
                + " (url=" + url + ") -- " + safeK8sStatus(res.body()));
        }
        return om.readTree(res.body());
    }

    private HttpRequest.Builder baseRequest(String url) {
        return HttpRequest.newBuilder(URI.create(url))
            .timeout(Duration.ofSeconds(15))
            .header("Authorization", "Bearer " + token);
    }

    /** Parse a Kubernetes Status object if present, otherwise return trimmed body. */
    private String safeK8sStatus(String body) {
        try {
            JsonNode n = om.readTree(body);
            if (n.has("kind") && "Status".equals(n.get("kind").asText())) {
                var reason = n.has("reason") ? n.get("reason").asText() : "";
                var msg = n.has("message") ? n.get("message").asText() : "";
                return ("reason=" + reason + ", message=" + msg).trim();
            }
        } catch (Exception ignore) { /* not JSON */ }
        return body != null ? body.substring(0, Math.min(300, body.length())).replaceAll("\\s+", " ") : "";
    }

    /** Tiny 'trust-all' client (lab only – mirrors curl -k). */
    private static HttpClient trustAllHttpClient() {
        try {
            TrustManager[] trustAll = new TrustManager[]{
                new X509TrustManager() {
                    public java.security.cert.X509Certificate[] getAcceptedIssuers() { return new java.security.cert.X509Certificate[]{}; }
                    public void checkClientTrusted(java.security.cert.X509Certificate[] xcs, String s) {}
                    public void checkServerTrusted(java.security.cert.X509Certificate[] xcs, String s) {}
                }
            };
            SSLContext sc = SSLContext.getInstance("TLS");
            sc.init(null, trustAll, new java.security.SecureRandom());

            return HttpClient.newBuilder()
                .sslContext(sc)
                .sslParameters(new SSLParameters() {{
                    setEndpointIdentificationAlgorithm(null); // disable hostname verification
                }})
                .version(HttpClient.Version.HTTP_1_1)
                .build();
        } catch (NoSuchAlgorithmException | KeyManagementException e) {
            throw new RuntimeException(e);
        }
    }
}


---------------------
public int restartVM(String ns, String vmName) throws Exception {
    String url = baseUrl + "/apis/subresources.kubevirt.io/v1/namespaces/"
               + ns + "/virtualmachines/" + vmName + "/restart";

    HttpRequest req = baseRequest(url)
        .header("Content-Type", "application/json")
        // .header("Accept", "application/json")  // REMOVE to avoid 406
        .PUT(HttpRequest.BodyPublishers.ofString("{}"))
        .build();

    HttpResponse<String> res = http.send(req, HttpResponse.BodyHandlers.ofString());
    if (res.statusCode() / 100 != 2) {
        throw new IOException("Restart failed: HTTP " + res.statusCode()
            + " -- " + safeK8sStatus(res.body()) + " (url=" + url + ")");
    }
    return res.statusCode();
}

