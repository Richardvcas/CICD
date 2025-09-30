Got it. Below is a drop-in Spring Boot mini-module you can add to your project to:

call the KubeVirt API

read VM (desired) vs VMI (current) CPU/Memory

decide if a restart is needed (spec ≠ live)

POST the restart subresource for that VM

You said you’ll hardcode the token — I left constants in the runner for apiServer/token/ns/vmName. This keeps it simple for your demo.

1) KubevirtApiService.java
package main.java.com.automation.kubevirt;

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

public class KubevirtApiService {

    private final String baseUrl;   // e.g. https://api.wh-ngcpntt1.svr.us.jpmchase.net:6443
    private final String token;     // Bearer <token>
    private final HttpClient http;
    private final ObjectMapper om = new ObjectMapper();

    public KubevirtApiService(String baseUrl, String token) {
        this.baseUrl = baseUrl;
        this.token = token;
        this.http   = trustAllHttpClient();
    }

    // ---------- public API ----------

    /** GET /apis/kubevirt.io/v1/namespaces/{ns}/virtualmachines/{vm} */
    public JsonNode getVM(String ns, String vmName) throws Exception {
        var url = baseUrl + "/apis/kubevirt.io/v1/namespaces/" + ns + "/virtualmachines/" + vmName;
        return getJson(url);
    }

    /** GET /apis/kubevirt.io/v1/namespaces/{ns}/virtualmachineinstances/{vm} (may be 404 if VM is not running) */
    public JsonNode getVMI(String ns, String vmName) throws Exception {
        var url = baseUrl + "/apis/kubevirt.io/v1/namespaces/" + ns + "/virtualmachineinstances/" + vmName;
        return getJsonOrNull(url);
    }

    /** POST /apis/subresources.kubevirt.io/v1/namespaces/{ns}/virtualmachines/{vm}/restart */
    public int restartVM(String ns, String vmName) throws Exception {
        var url = baseUrl + "/apis/subresources.kubevirt.io/v1/namespaces/" + ns + "/virtualmachines/" + vmName + "/restart";
        var req = baseRequest(url).POST(HttpRequest.BodyPublishers.noBody()).build();
        var res = http.send(req, HttpResponse.BodyHandlers.ofString());
        return res.statusCode();
    }

    // ---------- helpers ----------

    private JsonNode getJson(String url) throws Exception {
        var req = baseRequest(url).GET().build();
        var res = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() / 100 != 2) throw new IOException("GET failed " + res.statusCode() + " for " + url + " -> " + res.body());
        return om.readTree(res.body());
    }

    private JsonNode getJsonOrNull(String url) throws Exception {
        var req = baseRequest(url).GET().build();
        var res = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() == 404) return null;
        if (res.statusCode() / 100 != 2) throw new IOException("GET failed " + res.statusCode() + " for " + url + " -> " + res.body());
        return new ObjectMapper().readTree(res.body());
    }

    private HttpRequest.Builder baseRequest(String url) {
        return HttpRequest.newBuilder(URI.create(url))
                .header("Authorization", "Bearer " + token)
                .header("Accept", "application/json")
                .timeout(Duration.ofSeconds(15));
    }

    /** Very small ‘trust-all’ client for lab testing only. */
    private static HttpClient trustAllHttpClient() {
        try {
            TrustManager[] trustAllCerts = new TrustManager[]{ new X509TrustManager() {
                public java.security.cert.X509Certificate[] getAcceptedIssuers() { return new java.security.cert.X509Certificate[]{}; }
                public void checkClientTrusted(java.security.cert.X509Certificate[] xcs, String string) {}
                public void checkServerTrusted(java.security.cert.X509Certificate[] xcs, String string) {}
            }};
            SSLContext sc = SSLContext.getInstance("TLS");
            sc.init(null, trustAllCerts, new java.security.SecureRandom());
            return HttpClient.newBuilder()
                    .sslContext(sc)
                    .sslParameters(new SSLParameters(){{
                        setEndpointIdentificationAlgorithm(null); // disable hostname verification
                    }})
                    .version(HttpClient.Version.HTTP_1_1)
                    .build();
        } catch (NoSuchAlgorithmException | KeyManagementException e) {
            throw new RuntimeException(e);
        }
    }
}

2) VmResizeDecisionService.java
package main.java.com.automation.kubevirt;

import com.fasterxml.jackson.databind.JsonNode;

public class VmResizeDecisionService {

    /** Returns true if VM’s desired CPU/Mem (from VM) differs from current live (from VMI). */
    public boolean needsRestart(JsonNode vm, JsonNode vmi) {
        if (vmi == null) {
            // VM not running -> no need to restart; Argo changes will take effect on next start anyway
            return false;
        }

        int desiredVcpu = extractVcpuFromVM(vm);
        int liveVcpu    = extractVcpuFromVMI(vmi);

        long desiredMemMi = extractMemMiFromVM(vm);
        long liveMemMi    = extractMemMiFromVMI(vmi);

        boolean cpuDiff = desiredVcpu > 0 && liveVcpu > 0 && desiredVcpu != liveVcpu;
        boolean memDiff = desiredMemMi > 0 && liveMemMi > 0 && desiredMemMi != liveMemMi;

        return cpuDiff || memDiff;
    }

    // ---- extractors (VM desired) ----
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

    // ---- extractors (VMI live) ----
    private int extractVcpuFromVMI(JsonNode vmi) {
        JsonNode cpu = vmi.at("/spec/domain/cpu");
        if (cpu.isMissingNode()) return 0;
        int sockets = optInt(cpu.get("sockets"), 1);
        int cores   = optInt(cpu.get("cores"), 1);
        int threads = optInt(cpu.get("threads"), 1);
        return sockets * cores * threads;
    }

    private long extractMemMiFromVMI(JsonNode vmi) {
        // same fields but on VMI.spec
        String mem = null;
        var reqMem = vmi.at("/spec/domain/resources/requests/memory");
        if (!reqMem.isMissingNode()) mem = reqMem.asText();
        if (mem == null || mem.isBlank()) {
            var guest = vmi.at("/spec/domain/memory/guest");
            if (!guest.isMissingNode()) mem = guest.asText();
        }
        return parseQtyMi(mem);
    }

    // ---- utils ----
    private int optInt(JsonNode n, int d) { return (n == null || n.isMissingNode()) ? d : n.asInt(d); }

    /** Parse Kubernetes resource quantities to Mi (supports Ki, Mi, Gi). */
    private long parseQtyMi(String q) {
        if (q == null || q.isBlank()) return 0;
        q = q.trim().toUpperCase();
        try {
            if (q.endsWith("GI"))   return Math.round(Double.parseDouble(q.replace("GI","").trim()) * 1024);
            if (q.endsWith("MI"))   return Math.round(Double.parseDouble(q.replace("MI","").trim()));
            if (q.endsWith("KI"))   return Math.round(Double.parseDouble(q.replace("KI","").trim()) / 1024);
            // bare number -> bytes? treat as Mi for lab simplicity
            return Math.round(Double.parseDouble(q) / (1024*1024));
        } catch (Exception e) {
            return 0;
        }
    }
}

3) ResizeCheckRunner.java (profile: resize-check)
package main.java.com.automation.kubevirt.runner;

import com.fasterxml.jackson.databind.JsonNode;
import main.java.com.automation.kubevirt.KubevirtApiService;
import main.java.com.automation.kubevirt.VmResizeDecisionService;
import org.springframework.boot.CommandLineRunner;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Component;

@Component
@Profile("resize-check")
public class ResizeCheckRunner implements CommandLineRunner {

    // ---- hardcode for demo (replace for your env) ----
    private static final String API_SERVER = "https://api.wh-ngcpntt1.svr.us.jpmchase.net:6443";
    private static final String TOKEN      = "eyJhbGciOi...<paste lab token here>...";
    private static final String NS         = "icpwforge";
    private static final String VM_NAME    = "vmh02";

    @Override
    public void run(String... args) throws Exception {
        System.out.println("=== ResizeCheckRunner started ===");

        var api  = new KubevirtApiService(API_SERVER, TOKEN);
        var diff = new VmResizeDecisionService();

        JsonNode vm  = api.getVM(NS, VM_NAME);
        JsonNode vmi = api.getVMI(NS, VM_NAME);

        if (vmi == null) {
            System.out.println("[INFO] VMI not found (VM not running). No restart needed.");
            return;
        }

        boolean needs = diff.needsRestart(vm, vmi);

        System.out.println("--- Desired (from VM.spec) ---");
        System.out.println("vCPU:  " + vm.at("/spec/template/spec/domain/cpu").toString());
        System.out.println("Mem:   " + vm.at("/spec/template/spec/domain/resources/requests/memory").asText(null));

        System.out.println("--- Current (from VMI.spec) ---");
        System.out.println("vCPU:  " + vmi.at("/spec/domain/cpu").toString());
        System.out.println("Mem:   " + vmi.at("/spec/domain/resources/requests/memory").asText(null));

        if (needs) {
            System.out.println("[ACTION] Spec differs from live. Posting restart...");
            int code = api.restartVM(NS, VM_NAME);
            System.out.println("[RESULT] restart HTTP status: " + code + (code/100==2 ? " (OK)" : " (check errors)"));
        } else {
            System.out.println("[OK] Live config already matches desired. Restart NOT required.");
        }

        System.out.println("=== ResizeCheckRunner finished ===");
    }
}

How it decides “restart or not”

Desired: taken from VM.spec.template.spec.domain (what ArgoCD applied).

Current: taken from VMI.spec.domain (what the running QEMU domain is using now).

If either vCPU (sockets×cores×threads) or memory (Mi) differs → POST restart subresource:

POST /apis/subresources.kubevirt.io/v1/namespaces/{ns}/virtualmachines/{vm}/restart


That’s exactly what virtctl restart does under the hood.

How to run it

Add the three files above to your project (any package names are fine; keep the imports).

Make sure your pom.xml already has Jackson (Spring Boot starters normally include it).

Start with the resize-check profile:

mvn -q -DskipTests spring-boot:run -Dspring-boot.run.profiles=resize-check


Watch console logs:

It prints desired vs current,

Says if restart is required,

Calls the restart API and prints the HTTP status.

Note: This uses a trust-all SSL client to simplify testing against lab clusters with internal certs. For production, replace that with a proper truststore.
