// Explicit developer-only diagnostic: local silent RTC playback, no service session.
let localAudioCheck;
window.startLocalAudioCheck = async () => {
  try {
    const context = new AudioContext();
    const oscillator = context.createOscillator(), gain = context.createGain();
    gain.gain.value = 0;
    const destination = context.createMediaStreamDestination();
    oscillator.connect(gain).connect(destination); oscillator.start();
    const sender = new RTCPeerConnection(), receiver = new RTCPeerConnection();
    const audio = document.createElement('audio'); audio.autoplay = true;
    audio.setAttribute('playsinline', ''); document.body.append(audio);
    localAudioCheck = { context, oscillator, sender, receiver, audio };
    sender.onicecandidate = e => { if (e.candidate) receiver.addIceCandidate(e.candidate).catch(() => {}); };
    receiver.onicecandidate = e => { if (e.candidate) sender.addIceCandidate(e.candidate).catch(() => {}); };
    receiver.ontrack = e => {
      audio.srcObject = new MediaStream([e.track]);
      audio.play().then(() => diagnostic('rtc', { audioCheck: 'localRTCPlaying' }))
        .catch(error => diagnostic('rtc', { audioCheck: 'playFailed', message: error.message }));
    };
    sender.addTrack(destination.stream.getAudioTracks()[0], destination.stream);
    await sender.setLocalDescription(await sender.createOffer());
    await receiver.setRemoteDescription(sender.localDescription);
    await receiver.setLocalDescription(await receiver.createAnswer());
    await sender.setRemoteDescription(receiver.localDescription);
    await context.resume();
  } catch (error) { diagnostic('rtc', { audioCheck: 'loopbackFailed', message: error.message }); }
};
window.stopLocalAudioCheck = () => {
  const check = localAudioCheck; if (!check) return;
  check.sender.close(); check.receiver.close(); check.oscillator.stop();
  check.audio.srcObject = null; check.audio.remove(); check.context.close();
  localAudioCheck = null;
};
