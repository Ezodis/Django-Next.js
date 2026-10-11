const {matchLocale,textKey,tokens}=require('./core.cjs');
/** @param {{source: Record<string,string>, fetch?: typeof fetch, endpoint?: string, cache?: Function}} options */
function createService({source,fetch:request=global.fetch,endpoint=process.env.TRANSLATION_BUILD_ENDPOINT??'https://clients5.google.com/translate_a/t',cache}){
 const completed=new Map(),inflight=new Map(),queues=new Map();
 const resolvePhrase=(language,id)=>{
  const text=source[id],key=language+':'+id;
  if(completed.has(key))return Promise.resolve(completed.get(key));
  if(inflight.has(key))return inflight.get(key);
  const translate=()=>new Promise((resolve,reject)=>{
   let queue=queues.get(language);
   if(!queue){queue=[];queues.set(language,queue);setTimeout(()=>{queues.delete(language);void run(language,queue);},20);}
   queue.push({id,text,resolve,reject});
  });
  const task=(cache?cache(translate,['automatic-ui-v1',language,id,text],{revalidate:false})():translate())
   .then(value=>{completed.set(key,value);if(completed.size>10000)completed.delete(completed.keys().next().value);return value;})
   .finally(()=>inflight.delete(key));
  inflight.set(key,task);return task;
 };
 async function run(language,queue){
  for(let offset=0;offset<queue.length;){let size=0;const batch=[];
   while(offset<queue.length&&batch.length<35){const length=encodeURIComponent(queue[offset].text).length+3;if(batch.length&&size+length>6500)break;size+=length;batch.push(queue[offset++]);}
   try{
    const url=new URL(endpoint);url.search=new URLSearchParams({client:'dict-chrome-ex',sl:'auto',tl:language==='fil'?'tl':language});
    for(const item of batch)url.searchParams.append('q',item.text);
    const response=await request(url,{signal:AbortSignal.timeout(15000)});
    if(!response.ok)throw Error('Translation provider unavailable');
    const data=await response.json();
    if(!Array.isArray(data)||data.length!==batch.length)throw Error('Invalid translation batch');
    const validated=await Promise.all(data.map(async(entry,index)=>{
     let text=(typeof entry==='string'?entry:entry?.[0])?.replace(/\{\s*[vV]\s*(\d+)\s*\}/g,'{v$1}');
     if(typeof text!=='string'||!text.trim())throw Error('Empty translation');
     if(tokens(text)!==tokens(batch[index].text)){
      const parts=batch[index].text.split(/(\{v\d+\})/g);
      const fragments=parts.filter(part=>!/^\{v\d+\}$/.test(part)&&/\p{L}/u.test(part));
      const repair=new URL(endpoint);repair.search=new URLSearchParams({client:'dict-chrome-ex',sl:'auto',tl:language==='fil'?'tl':language});
      for(const fragment of fragments)repair.searchParams.append('q',fragment);
      const repairedResponse=await request(repair,{signal:AbortSignal.timeout(15000)});
      if(!repairedResponse.ok)throw Error('Translation repair unavailable');
      const repaired=await repairedResponse.json();
      if(!Array.isArray(repaired)||repaired.length!==fragments.length)throw Error('Invalid translation repair');
      let fragmentIndex=0;
      text=parts.map(part=>{
       if(/^\{v\d+\}$/.test(part)||!/\p{L}/u.test(part))return part;
       const entry=repaired[fragmentIndex++],value=typeof entry==='string'?entry:entry?.[0];
       if(typeof value!=='string'||!value.trim())throw Error('Empty repaired translation');
       return (part.match(/^\s*/)?.[0]??'')+value.trim()+(part.match(/\s*$/)?.[0]??'');
      }).join('');
     }
     if(tokens(text)!==tokens(batch[index].text))throw Error('Invalid translation placeholders');
     return (batch[index].text.match(/^\s*/)?.[0]??'')+text.trim()+(batch[index].text.match(/\s*$/)?.[0]??'');
    }));
    batch.forEach((item,index)=>item.resolve(validated[index]));
   }catch(error){batch.forEach(item=>item.reject(error));}
  }
 }
 return async ({language,ids})=>{
  const locale=matchLocale(language);
  if(!locale||!Array.isArray(ids)||!ids.length||ids.length>35||ids.some(id=>typeof id!=='string'||!Object.hasOwn(source,id)||textKey(source[id])!==id))throw Error('Invalid translation request');
  const unique=[...new Set(ids)];
  const values=await Promise.all(unique.map(id=>resolvePhrase(locale,id)));
  return Object.fromEntries(unique.map((id,index)=>[id,values[index]]));
 };
}
module.exports={createService};
