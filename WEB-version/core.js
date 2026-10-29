/* Pure browser-domain logic, shared with the regression tests. No server runtime. */
(function (root) {
  class Queue {
    constructor() { this.items=[]; this.index=-1; this.shuffle=false; this.repeat='off'; this.serial=0; }
    get tracks() { return this.items.map(item=>item.track); }
    set(tracks,index) {
      this.items=tracks.map(track=>({track,key:++this.serial,order:this.serial})); this.index=index;
      if(this.shuffle) { const chosen=this.items.splice(index,1)[0]; this.mix(this.items); this.items.unshift(chosen);this.index=0; }
    }
    mix(items) { for(let i=items.length-1;i>0;i--) { const j=Math.floor(Math.random()*(i+1));[items[i],items[j]]=[items[j],items[i]]; } }
    toggleShuffle() {
      this.shuffle=!this.shuffle;const future=this.items.splice(this.index+1);
      if(this.shuffle)this.mix(future);else future.sort((a,b)=>a.order-b.order); this.items.push(...future);
    }
    add(track,next=false) { const item={track,key:++this.serial,order:this.serial}; this.items.splice(next?this.index+1:this.items.length,0,item); }
    remove(index) { if(index===this.index||index<0||index>=this.items.length)return;this.items.splice(index,1);if(index<this.index)this.index--; }
    move(from,to) {
      if(from<0||to<0||from>=this.items.length||to>=this.items.length)return;
      const current=this.items[this.index]?.key;this.items.splice(to,0,this.items.splice(from,1)[0]); this.index=this.items.findIndex(x=>x.key===current);
    }
    clearUpcoming() { this.items=this.items.slice(0,this.index+1); }
  }
  class Listening {
    constructor() { this.reset(); }
    reset() { this.last=0;this.amount=0;this.media=0;this.newPlay=true;this.scored=false;this.scorePending=false; }
    seek(position) { this.last=position; }
    sample(position,{playing,speed=1,duration=0,privateSession=false,buffering=false}) {
      const delta=position-this.last;this.last=position;
      if(!playing||privateSession||buffering||delta<=0||delta>5)return;
      this.amount+=delta*1000/speed;this.media+=delta;
      if(!this.scored&&duration>0&&this.media>=duration*.85){this.scored=true;this.scorePending=true;}
    }
    take() {
      if(this.amount<1)return null;
      const result={milliseconds:Math.min(60000,Math.round(this.amount)),newPlay:this.newPlay,fullPlay:this.scorePending};
      this.amount=0;this.newPlay=false;this.scorePending=false;return result;
    }
  }
  function replay(entries,year) {
    const selected=entries.filter(e=>e.day.slice(0,4)===String(year));const songs=new Map(),artists=new Map(),months=Array(12).fill(0),days=new Set();let ms=0,plays=0;
    for(const e of selected){ms+=e.milliseconds;plays+=e.plays;days.add(e.day);months[Number(e.day.slice(5,7))-1]+=e.milliseconds;
      const old=songs.get(e.track.trackId)||{track:e.track,milliseconds:0};old.milliseconds+=e.milliseconds;songs.set(e.track.trackId,old);
      artists.set(e.track.artistName,(artists.get(e.track.artistName)||0)+e.milliseconds);
    }
    return {minutes:Math.floor(ms/60000),plays,days:days.size,uniqueSongs:songs.size,uniqueArtists:artists.size,
      songs:[...songs.values()].sort((a,b)=>b.milliseconds-a.milliseconds),artists:[...artists].sort((a,b)=>b[1]-a[1]),months:months.map(n=>Math.floor(n/60000))};
  }
  const api={Queue,Listening,replay};if(typeof module!=='undefined')module.exports=api;else root.Rhythm=api;
})(typeof globalThis!=='undefined'?globalThis:this);
