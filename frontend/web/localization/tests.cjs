const {test}=require('node:test'),assert=require('node:assert/strict');
const {compile}=require('./compiler.cjs');
const {detectLocale,matchLocale,direction,textKey}=require('./core.cjs');
const {createService}=require('./service.cjs');
test('device languages normalize scripts and aliases with a safe fallback',()=>{
 assert.equal(detectLocale(['ru-RU','en']),'ru');assert.equal(detectLocale(['de-DE']),'de');
 assert.equal(detectLocale(['ar-SA']),'ar');assert.equal(direction('ar'),'rtl');
 assert.equal(matchLocale('zh-Hant-HK'),'zh-TW');assert.equal(matchLocale('no-NO'),'nb');
 assert.equal(detectLocale(['invalid language','fr-FR']),'fr');assert.equal(matchLocale('../../secret'),undefined);
});
test('new JSX phrases and accessibility labels compile without altering private expressions or handlers',()=>{
 const source="'use client'; export default function Page(){return <section><button onClick={save} aria-label=\"Save changes\">Save</button><p>{person.name}</p><p>{enabled ? 'Ready' : 'Waiting'}</p><div translate=\"no\">Private literal</div><code>Raw code</code></section>}";
 const result=compile(source,'page.tsx');
 for(const text of ['Save changes','Save','Ready','Waiting'])assert.equal(result.messages[textKey(text)],text);
 assert.ok(!Object.values(result.messages).includes('Private literal'));
 assert.ok(!Object.values(result.messages).includes('Raw code'));
 assert.match(result.code,/onClick=\{save\}/);assert.match(result.code,/\{person.name\}/);
 assert.ok(result.code.indexOf('use client')<result.code.indexOf('import'));
 assert.match(result.code,/__SharedAutoElement/);
});
test('dynamic template values remain separate from authored source phrases',()=>{
 const result=compile('export default ()=> <p>{`Hello ${person.name}, you have ${count} messages`}</p>','page.tsx');
 assert.deepEqual(Object.values(result.messages),['Hello {v0}, you have {v1} messages']);
 assert.match(result.code,/values=\{\[person.name, count\]\}/);
});
test('JSX entities are decoded once and remain valid text',()=>{
 const result=compile('<p>Privacy &amp; Terms &copy;</p>','page.tsx');
 assert.deepEqual(Object.values(result.messages),['Privacy & Terms ©']);
});
test('select option values remain their original values while labels translate',()=>{
 const result=compile('<select><option>Weekly</option><option value="month">Monthly</option></select>','page.tsx');
 assert.match(result.code,/value="Weekly"/);assert.match(result.code,/value="month"/);
});
test('runtime translation batches static phrases, deduplicates requests and caches results',async()=>{
 const source=Object.fromEntries(['Welcome','Save'].map(text=>[textKey(text),text]));let calls=0;
 const service=createService({source,fetch:async url=>{calls++;assert.deepEqual(new URL(url).searchParams.getAll('q'),['Welcome','Save']);return {ok:true,json:async()=>['Willkommen','Speichern']};}});
 const request={language:'de-DE',ids:Object.keys(source)};
 const [first,second]=await Promise.all([service(request),service(request)]);
 assert.deepEqual(first,second);assert.equal(first[textKey('Save')],'Speichern');
 await service(request);assert.equal(calls,1);
 await assert.rejects(service({language:'de',ids:[textKey('A private message')]}));
 assert.equal(calls,1);
});
test('failed or malformed translations are not cached and interpolation tokens survive',async()=>{
 const phrase='Hello {v0}',source={[textKey(phrase)]:phrase};let calls=0;
 const service=createService({source,fetch:async()=>{calls++;if(calls===1)return {ok:false};return {ok:true,json:async()=>['Hallo {v0}']};}});
 await assert.rejects(service({language:'de',ids:Object.keys(source)}));
 const translated=await service({language:'de',ids:Object.keys(source)});
 assert.equal(translated[textKey(phrase)],'Hallo {v0}');assert.equal(calls,2);
});
test('machine-translated placeholder names are repaired without sending interpolated values',async()=>{
 const phrase='Hello {v0}',source={[textKey(phrase)]:phrase};let calls=0;
 const service=createService({source,fetch:async url=>{calls++;const phrases=new URL(url).searchParams.getAll('q');assert.ok(!phrases.includes('Private Person'));return {ok:true,json:async()=>[calls===1?'Hallo übersetzterName':'Hallo']};}});
 const translated=await service({language:'de',ids:Object.keys(source)});
 assert.equal(translated[textKey(phrase)],'Hallo {v0}');assert.equal(calls,2);
});
