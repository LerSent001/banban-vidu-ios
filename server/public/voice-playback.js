// Detect actual incoming voice, retaining pauses within a reply as one turn.
class VoicePlayback {
  constructor(onChange, holdMs = 1400) {
    this.onChange = onChange;
    this.holdMs = holdMs;
    this.active = false;
    this.lastSound = -Infinity;
  }
  sample(volume, now = performance.now()) {
    if (volume > 0.015) this.lastSound = now;
    const active = now - this.lastSound < this.holdMs;
    if (active !== this.active) {
      this.active = active;
      this.onChange(active);
    }
  }
}
if (typeof module !== 'undefined') module.exports = { VoicePlayback };
