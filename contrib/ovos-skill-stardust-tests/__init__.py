# Capcom / OVOS skill for the Stardust test runner.
# Drop into ~/.local/share/mycroft/skills/ovos-skill-stardust-tests/
# or the OVOS skills dir. Requires tests/run-test.sh in the Stardust repo.
#
# Bus: emits stardust.tests.result with each JSON line.
# Spoken: uses the SPEAK: line from --speak.

from ovos_workshop.skills import OVOSSkill
from ovos_workshop.decorators import intent_handler
import os
import subprocess

REPO = os.environ.get("STARDUST_REPO", "/home/landy/Apps/Stardust")
RUNNER = os.path.join(REPO, "tests", "run-test.sh")

class StardustTestsSkill(OVOSSkill):
    def _run(self, extra):
        cmd = [RUNNER, "--json", "--speak"] + extra
        try:
            out = subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError as e:
            out = e.output or ""
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("{"):
                self.bus.emit(self.Message("stardust.tests.result", {"raw": line}))
            if line.startswith("SPEAK:"):
                self.speak(line.split(":", 1)[1].strip())
        return out

    @intent_handler("daily.intent")
    def handle_daily(self, message):
        self.speak("Running the daily Stardust checks.")
        self._run(["-n", "daily"])

    @intent_handler("all.intent")
    def handle_all(self, message):
        self.speak("Running all Stardust tests.")
        self._run(["--all"])

    @intent_handler("diagnose.intent")
    def handle_diagnose(self, message):
        self.speak("Diagnosing the Stardust stack.")
        self._run(["--diagnose"])

    @intent_handler("intent.intent")
    def handle_phrase(self, message):
        phrase = message.data.get("utterance") or message.data.get("phrase") or ""
        self.speak("Running Stardust tests.")
        self._run(["--intent", phrase])
