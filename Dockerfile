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
