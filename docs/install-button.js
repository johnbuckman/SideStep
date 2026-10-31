// SideStep one-click install button: identical to the one on johnbuckman.github.io/SideStep
// (see SideStep docs/install-button.html). Mounts every <span class="sidestep-install">.
(function () {
  function mount(el){
    var repo=el.getAttribute("data-repo"); if(!repo) return;
    var dl=el.getAttribute("data-installer")||"";
    var app=el.getAttribute("data-app")||repo.split("/").pop();
    var btn=document.createElement("a");
    btn.textContent="Install "+app+" with SideStep";
    btn.href="sidestep://install?repo="+encodeURIComponent(repo);
    btn.style.cssText="display:inline-block;padding:12px 22px;border-radius:10px;background:#0a84ff;color:#fff;font-weight:600;text-decoration:none;cursor:pointer;";
    var note=document.createElement("div"); note.style.cssText="margin-top:10px;font-size:14px;opacity:.75;"; note.style.display="none";
    // SideStep is a Mac app that sideloads onto an iPhone/iPad over USB; both the sidestep://
    // hand-off and the .app installer are useless off a Mac. If this page isn't on a Mac, say why
    // instead of firing a link that silently does nothing. iPadOS Safari masquerades as a Mac (UA
    // "Macintosh", platform "MacIntel"), so a REAL Mac is Mac-like AND non-touch; an iPad is
    // Mac-like WITH touch (maxTouchPoints>1) — that's the discriminator.
    var macLike=/Mac/.test(navigator.platform||navigator.userAgent||"");
    var touch=(navigator.maxTouchPoints||0)>1;
    if(!(macLike&&!touch)){
      var onApple=/iPhone|iPad|iPod/.test(navigator.userAgent||"")||(macLike&&touch);
      btn.removeAttribute("href"); btn.style.background="#8e8e93"; btn.style.cursor="default"; btn.style.pointerEvents="none"; btn.setAttribute("aria-disabled","true");
      // A site button class can be a fixed-height pill (line-height≈45px, overflow:hidden,
      // white-space:nowrap) that CLIPS a 2nd line — relax those so the warning below shows.
      btn.style.height="auto"; btn.style.lineHeight="1.3"; btn.style.overflow="visible"; btn.style.whiteSpace="normal"; btn.style.paddingTop="10px"; btn.style.paddingBottom="10px";
      // "⚠️ Must be run on a Mac" is a 2nd line of text INSIDE the disabled button.
      var warn=document.createElement("span"); warn.textContent="⚠️ Must be run on a Mac"; warn.style.cssText="display:block;font-size:.85em;font-weight:600;margin-top:2px;"; btn.appendChild(warn);
      note.textContent=onApple
        ? "SideStep installs "+app+" onto your iPhone or iPad from a Mac. Open this page on a Mac, then plug this device in with a USB cable."
        : "SideStep runs on a Mac. Open this page on a Mac to install "+app+".";
      note.style.display="block"; note.style.opacity="1";
      el.appendChild(btn); el.appendChild(note); return;
    }
    var downloaded=false;
    function download(){ if(!dl) return; var a=document.createElement("a"); a.href=dl; a.setAttribute("download",""); document.body.appendChild(a); a.click(); document.body.removeChild(a); }
    btn.addEventListener("click",function(ev){
      if(downloaded) return;                       // 2nd click: button now points at the installer — let it download
      ev.preventDefault();                         // launch the app ourselves; letting the <a href="sidestep://"> navigate is what pops Safari's "address is invalid" dialog
      btn.textContent="Installing…";               // immediate feedback that the tap registered
      // Key off document.hidden ONLY — not window "blur", which also fires when the browser
      // shows a "scheme has no registered handler" alert, wrongly suppressing the fallback.
      var launched=false;
      document.addEventListener("visibilitychange",function vc(){if(document.hidden){launched=true;document.removeEventListener("visibilitychange",vc);}});
      var scheme="sidestep://install?repo="+encodeURIComponent(repo);
      // Safari pops a blocking "address is invalid" dialog when a custom scheme has no handler
      // and you navigate the TOP window — but NOT inside a hidden iframe, where a missing handler
      // fails silently. Other browsers block iframe scheme-launches, so navigate the window there.
      var isSafari=/^((?!chrome|chromium|android|crios|fxios|edg).)*safari/i.test(navigator.userAgent)&&/apple/i.test(navigator.vendor||"");
      if(isSafari){
        var ifr=document.createElement("iframe"); ifr.style.display="none"; ifr.src=scheme;
        document.body.appendChild(ifr);
        setTimeout(function(){ if(ifr.parentNode) ifr.parentNode.removeChild(ifr); },1000);
      } else { window.location.href=scheme; }
      setTimeout(function(){
        if(launched) return;                        // SideStep opened
        if(!dl){ note.textContent="Install SideStep first, then click again."; note.style.display="block"; btn.textContent="Install "+app+" with SideStep"; return; }
        download();                                 // SideStep isn't installed → fetch the installer
        downloaded=true; btn.href=dl; btn.setAttribute("download","");
        btn.textContent="Run the "+app+" installer now";
        note.textContent="It’s going to your Downloads folder now.";
        note.style.display="block";
      },1500);
    });
    el.appendChild(btn); el.appendChild(note);
  }
  function init(){document.querySelectorAll(".sidestep-install").forEach(mount);}
  if(document.readyState==="loading") document.addEventListener("DOMContentLoaded",init); else init();
})();
