"use strict";
// Build 26266538: RenewalPlayer.GetLocalPlayer/GetSharedSettings;
// PBZSettingsShared.MusicVolume/AmbientVolume and EAudioVolumeType in usmap;
// BonusCollection.applyVolume uses SetAudioVolume(type, normalized volume).
// Only the live mix changes. Never call a settings setter, Save, PauseAll or
// StopAll. Leave SFX/UI/voice alone so a spatial audition remains audible.
const mixes=new WeakMap();
function begin(UE,context,report=()=>{}){
    const changed=[];let ended=false,settings,sound,mix=null;
    const notify=event=>report({code:"PREVIEW_AUDIO_FOCUS",...event});
    function restore(){
        if(ended)return;ended=true;
        if(mix){
            mix.users--;
            if(mix.users>0)return;
            mixes.delete(settings);mix.restore();return;
        }
        restoreChannels();
    }
    function restoreChannels(){
        for(const c of changed.splice(0).reverse()){
            try{
                // Respect a real preference edited during this short lease.
                const current=settings[c.field],value=valid(current)?current:c.before;
                sound.SetAudioVolume(c.type,value);
                notify({stage:"restored",channel:c.field,value});
            }catch(error){notify({stage:"restore_failed",channel:c.field,detail:String(error)});}
        }
    }
    try{
        const local=UE.PBZBlueprintFunctionLibrary.GetLocalPlayer(context);
        settings=local?.GetSharedSettings();
        sound=UE.SubsystemBlueprintLibrary.GetWorldSubsystem(context,UE.PBZSoundFXSubsystem.StaticClass());
        if(!settings || !sound || typeof sound.SetAudioVolume!=="function")throw Error("AUDIO_VOLUME_UNAVAILABLE");
        const existing=mixes.get(settings);
        if(existing){mix=existing;mix.users++;return restore;}
        const channels=[{field:"MusicVolume",type:UE.EAudioVolumeType.MusicVolume},{field:"AmbientVolume",type:UE.EAudioVolumeType.AmbVolume}];
        // Validate all readbacks before changing either channel. Unsupported
        // builds or unavailable settings leave the background unchanged.
        for(const c of channels){c.before=settings[c.field];if(!valid(c.before)||!Number.isInteger(c.type))throw Error("AUDIO_VOLUME_READBACK_UNAVAILABLE");}
        for(const c of channels){
            changed.push(c);sound.SetAudioVolume(c.type,c.before*.2);
            notify({stage:"lowered",channel:c.field,before:c.before,value:c.before*.2});
        }
        mix={users:1,restore:restoreChannels};mixes.set(settings,mix);
    }catch(error){restore();notify({stage:"unavailable",detail:String(error)});}
    return restore;
}
function valid(value){return typeof value==="number"&&Number.isFinite(value)&&value>=0&&value<=1;}
module.exports={begin};
