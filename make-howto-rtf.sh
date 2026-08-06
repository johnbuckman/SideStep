#!/bin/bash
# Generate "How-this-works.rtf" (the doc that ships in the SideStepWizard DMG) from
# HTML via textutil. Shared by package-wizard-dmg.sh and notarize-wizard.sh.
#   ./make-howto-rtf.sh <output.rtf>
set -e
OUT="${1:?usage: make-howto-rtf.sh <output.rtf>}"
TMP="$(mktemp -d)"; HTMLDOC="$TMP/how.html"
cat > "$HTMLDOC" <<'HTML'
<html><body style="font-family:-apple-system,Helvetica,sans-serif;font-size:13px;">
<h1>SideStep Wizard — how it works</h1>
<p>This app lets you hand anyone a <b>one-click installer</b> for your iOS app — no
Xcode, no developer account on their end.</p>

<h2>Make your installer</h2>
<ol>
<li>Open <b>SideStepWizard.app</b>.</li>
<li>Type a short <b>tiny name</b> for your app (for example <code>magnatune-app</code>).
As you type, the wizard checks <b>tinyurl.com/&lt;name&gt;</b>:
  <ul>
  <li>If it already points to your GitHub repo, it’s <b>reused</b> — nothing else to do.</li>
  <li>If it doesn’t exist yet, click <b>Create it for me</b> and enter your
  <b>GitHub repository</b> (the one whose <b>Releases</b> hold your <code>.ipa</code>).
  The wizard registers <b>tinyurl.com/&lt;name&gt;</b> → your repo for you.</li>
  </ul>
</li>
<li>Click <b>Create Installer</b>. A file named <b>&lt;name&gt; installer</b> appears on
your Desktop (e.g. <b>magnatune-app installer</b>).</li>
</ol>
<p>&nbsp;</p>
<p>That Desktop app is <i>the same signed, notarized app</i>, just renamed — so it
carries no Gatekeeper warning. Your GitHub repo isn’t baked into the file; it’s found at
run time through the tinyurl, which keeps the name short and lets you repoint it later.
The installer contains no copy of SideStep; it downloads the latest SideStep from GitHub
the moment it runs, so nobody is ever stuck on a stale version.</p>

<h2>What your users get</h2>
<p>When someone opens <b>&lt;name&gt; installer</b>, it: installs SideStep, walks them
through readying their iPhone/iPad (plug in, Trust, Developer Mode), then opens SideStep
to your app so they tap <b>Install</b>. After it installs, they trust the developer under
Settings ▸ General ▸ VPN &amp; Device Management.</p>

<h2>Add a button to your website</h2>
<p>SideStepWizard shows you a ready-to-paste snippet after it builds your installer (with
your repo and download link already filled in). The generic version is below — set
<code>data-repo</code> to your <code>owner/name</code> and <code>data-installer</code> to
your hosted installer .zip. If a visitor already has SideStep, the button installs your
app straight away; otherwise it links them to your installer download.</p>
<pre style="background:#f2f2f2;padding:10px;border-radius:6px;white-space:pre-wrap;font-size:11px;">
&lt;span class="sidestep-install"
      data-repo="owner/name"
      data-installer="https://johnbuckman.github.io/SideStep/installers/name%20installer.app.zip"&gt;&lt;/span&gt;
&lt;script&gt;
(function(){
function m(el){var repo=el.getAttribute("data-repo");if(!repo)return;
var dl=el.getAttribute("data-installer")||"";
var b=document.createElement("a");b.textContent="Install with SideStep";
b.href="sidestep://install?repo="+encodeURIComponent(repo);
b.style.cssText="display:inline-block;padding:12px 22px;border-radius:10px;background:#0a84ff;color:#fff;font-weight:600;text-decoration:none;";
var d=document.createElement("div");d.style.cssText="margin-top:14px;font-size:14px;display:none;";
if(dl){d.innerHTML='SideStep isn’t installed yet. &lt;a href="'+dl+'"&gt;Download the installer&lt;/a&gt;.';}
b.addEventListener("click",function(){var l=false;function k(){l=true;}
window.addEventListener("blur",k,{once:true});
document.addEventListener("visibilitychange",function v(){if(document.hidden){l=true;document.removeEventListener("visibilitychange",v);}});
setTimeout(function(){window.removeEventListener("blur",k);if(!l)d.style.display="block";},1500);});
el.appendChild(b);el.appendChild(d);}
document.querySelectorAll(".sidestep-install").forEach(m);})();
&lt;/script&gt;
</pre>
</body></html>
HTML
textutil -convert rtf -inputencoding UTF-8 -output "$OUT" "$HTMLDOC"
rm -rf "$TMP"
