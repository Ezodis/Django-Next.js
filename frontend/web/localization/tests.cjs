const {test}=require('node:test'),assert=require('node:assert/strict');
const {compile}=require('./compiler.cjs');
const {detectLocale,matchLocale,direction,textKey}=require('./core.cjs');
const {createService}=require('./service.cjs');

test('translator aliases register new copy and reject unsafe dynamic templates',()=>{
 const result=compile(`const localize=useInterfaceTranslator();const caption=localize('New checkout caption');`,'page.tsx');
 assert.equal(result.messages[textKey('New checkout caption')],'New checkout caption');
 assert.throws(()=>compile('const localize=useInterfaceTranslator();localize(`Hello ${person.name}`);','page.tsx'),/static source and separate values/);
});

test('direct production builds invoke the coverage gate',()=>{
 const ts=require('typescript'),Module=require('node:module');
 const file=path.join(__dirname,'../next.config.shared.ts'),compiledModule=new Module(file,module);
 compiledModule.filename=file;compiledModule.paths=Module._nodeModulePaths(__dirname);
 const original=compiledModule.require.bind(compiledModule);let called=false;
 compiledModule.require=id=>id==='./localization/prepare.cjs'?{verify:()=>{called=true;throw Error('Incomplete production dictionary');},prepare:()=>{throw Error('Production must not silently prepare source');}}:original(id);
 compiledModule._compile(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,esModuleInterop:true}}).outputText,file);
 const before=process.env.NODE_ENV;
 try{process.env.NODE_ENV='production';assert.throws(()=>compiledModule.exports.withSharedDevConfig({}),/Incomplete production dictionary/);assert.equal(called,true);}
 finally{if(before===undefined)delete process.env.NODE_ENV;else process.env.NODE_ENV=before;}
});

test('helper option placeholders are discovered without translating input values',()=>{
 const result=compile(`const field=(options:{placeholder:string},value:string)=><input placeholder={options.placeholder} value={value}/>; const page=field({placeholder:'Your delivery address'},user.address);`,'page.tsx');
 assert.equal(result.messages[textKey('Your delivery address')],'Your delivery address');
 assert.match(result.code,/translationCandidates/);assert.match(result.code,/value=\{value\}/);
 const defaults=compile(`const field=(label='Recipient',options={placeholder:'Additional information'})=><label>{label}<input placeholder={options.placeholder}/></label>;`,'page.tsx');
 for(const phrase of ['Recipient','Additional information'])assert.equal(defaults.messages[textKey(phrase)],phrase);
});

test('mapped labels, spreads and local component props expose complete authored phrases',()=>{
 const source="function Tag({label}){return <span>{label}</span>} const tags=[...(sort?[{label:`Browse: ${({newest:'Newest',oldest:'Oldest'}[sort]||sort)}`}]:[]),...terms.map(term=>({label:`Author: ${term}`}))]; export default()=>tags.filter(Boolean).map(tag=><Tag label={tag.label}/>);";
 const result=compile(source,'page.tsx');
 for(const phrase of ['Browse: Newest','Browse: Oldest','Browse: {v0}','Author: {v0}'])assert.equal(result.messages[textKey(phrase)],phrase);
 assert.match(result.code,/source=\{label\} candidates=/);
 assert.match(result.code,/<Tag label=\{tag.label\}/);
 assert.ok(!Object.values(result.messages).includes('newest'));
});

test('tuple options, object destructuring, aliases and indexed UI dictionaries preserve IDs',()=>{
 const result=compile("const options=[['new','Newest'],['old','Oldest']] as const; const extra={label:'Ready'}; const labels={low:'Lowest price',high:'Highest price'}; export default()=> <>{options.map(([id,caption])=><button data-id={id}>{caption}</button>)}{[{...extra}].map(({label:caption})=><p>{caption}</p>)}<span>{labels[sort]}</span></>;",'page.tsx');
 for(const phrase of ['Newest','Oldest','Ready','Lowest price','Highest price'])assert.equal(result.messages[textKey(phrase)],phrase);
 assert.ok(!Object.values(result.messages).includes('new'));
 assert.match(result.code,/data-id=\{id\}/);
});

test('private values, computed private fields, defaults and opted-out content stay unregistered',()=>{
 const result=compile("const personName='Private Person';const secrets={a:'Private credential'};function Card({fullName='Private Default'}){return <p>{fullName}</p>} const page=<><Card/><p>{personName}</p><p>{`Owner: ${personName}`}</p><p>{secrets[key]}</p><span title={`${personName} (@${username})`}/><section translate='no'>{[{label:'Private label'}].map(item=><p>{item.label}</p>)}</section></>;",'page.tsx');
 for(const phrase of ['Private Person','Private credential','Private Default','Private label'])assert.ok(!Object.values(result.messages).some(text=>text.includes(phrase)),phrase);
 assert.equal(result.messages[textKey('Owner: {v0}')],'Owner: {v0}');
 assert.match(result.code,/\{secrets\[key\]\}/);
});

test('imported widgets require explicit localization only for authored UI props',()=>{
 for(const prop of ['label','title','placeholder','aria-label','alt'])assert.throws(()=>compile(`import Widget from './widget';export default()=> <Widget ${prop}="New interface caption"/>;`,'page.tsx'),/page.tsx:1: Interface prop .* useInterfaceTranslator/);
 assert.doesNotThrow(()=>compile("import Widget from './widget';const translate=useInterfaceTranslator();export default()=> <><Widget label={translate('Ready')} value={password}/><Widget title={`${fullName} (@${username})`} placeholder='123456'/><div translate='no'><Widget title='Private document'/></div></>;",'page.tsx'));
});

test('specific alternatives win over generic interpolation templates',()=>{
 const {matchAuthoredPhrase}=require('./core.cjs');
 assert.deepEqual(matchAuthoredPhrase('Browse: Newest',['Browse: {v0}','Browse: Newest']),{source:'Browse: Newest'});
 assert.deepEqual(matchAuthoredPhrase('Show 3 newest books',['Show {v0}','Show {v0} newest books']),{source:'Show {v0} newest books',values:['3']});
});

test('nested template alternatives localize on the first render without changing handlers or input values',()=>{
 const React=require('react'),{renderToStaticMarkup}=require('react-dom/server'),ts=require('typescript'),Module=require('node:module');
 const file=path.join(__dirname,'fixture.tsx');
 const source="function Tag({label}){return <span>{label}</span>} const sortLabels={newest:'Newest',oldest:'Oldest'}; export default function Page(){const tags=[{label:`Browse: ${sortLabels['newest']}`}];return <><button title={`Browse: ${sortLabels['newest']}`}>{`Browse: ${sortLabels['newest']}`}</button>{tags.map(tag=><Tag key={tag.label} label={tag.label}/>)}<input value='Newest' readOnly/></>;}";
 const result=compile(source,file),loaded=new Module(file,module);loaded.filename=file;loaded.paths=Module._nodeModulePaths(__dirname);
 require.extensions['.tsx']=(mod,name)=>mod._compile(ts.transpileModule(fs.readFileSync(name,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,jsx:ts.JsxEmit.ReactJSX,esModuleInterop:true}}).outputText,name);
 loaded._compile(ts.transpileModule(result.code,{compilerOptions:{module:ts.ModuleKind.CommonJS,jsx:ts.JsxEmit.ReactJSX,esModuleInterop:true}}).outputText,file);
 const {AutomaticTranslationProvider}=require('./client.tsx');
 const html=renderToStaticMarkup(React.createElement(AutomaticTranslationProvider,{initial:{language:'es',catalog:{[textKey('Browse: Newest')]:'Explorar: Más recientes'}}},React.createElement(loaded.exports.default)));
 assert.equal((html.match(/Explorar: Más recientes/g)||[]).length,3);
 assert.ok(!html.includes('Browse:'));assert.ok(html.includes('value="Newest"'));
});

test('coverage verification rejects undiscovered UI and incomplete locales without modifying files',()=>{
 const {prepare,verify}=require('./prepare.cjs');
 const {locales}=require('./core.cjs');
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'translation-coverage-'));
 try{
  fs.mkdirSync(path.join(root,'app'));fs.mkdirSync(path.join(root,'messages'));
  fs.writeFileSync(path.join(root,'package.json'),'{}');
  fs.writeFileSync(path.join(root,'app/page.tsx'),'<p>New interface heading</p>');
  const manifest=path.join(root,'messages/automatic-source.json');fs.writeFileSync(manifest,'{}');
  assert.throws(()=>verify(root),/1 unregistered phrases/);assert.equal(fs.readFileSync(manifest,'utf8'),'{}');
  prepare(root);const source=JSON.parse(fs.readFileSync(manifest,'utf8'));
  fs.mkdirSync(path.join(root,'messages/automatic'));
  for(const locale of locales)fs.writeFileSync(path.join(root,'messages/automatic',locale+'.json'),JSON.stringify(Object.fromEntries(Object.entries(source).map(([id,text])=>[id,{source:text,translation:'Localized heading'}]))));
  assert.equal(verify(root),1);
  fs.writeFileSync(path.join(root,'messages/automatic/es.json'),'{}');
  const before=fs.readFileSync(manifest,'utf8');assert.throws(()=>verify(root),/es: 1/);assert.equal(fs.readFileSync(manifest,'utf8'),before);
 }finally{assert.ok(path.resolve(root).startsWith(path.resolve(os.tmpdir())+path.sep));fs.rmSync(root,{recursive:true,force:true});}
});

test('new helper labels and computed captions are discovered without changing identifiers or private data',()=>{
 const result=compile(`const field=(label:string,value:string)=><label htmlFor={label}>{label}<input value={value}/></label>; const searchLabel=count?\`Show \${count} books\`:'Search books'; export default()=> <>{field('New delivery label',person.name)}<button>{searchLabel}</button><p>{personName}</p></>; const personName='Private Person';`,'page.tsx');
 for(const phrase of ['New delivery label','Show {v0} books','Search books'])assert.equal(result.messages[textKey(phrase)],phrase);
 assert.ok(!Object.values(result.messages).includes('Private Person'));
 assert.match(result.code,/htmlFor=\{label\}/);assert.match(result.code,/value=\{value\}/);assert.match(result.code,/candidates=/);
});

test('inferred phrases match only authored patterns and preserve interpolation values',()=>{
 const {matchAuthoredPhrase}=require('./core.cjs');
 assert.deepEqual(matchAuthoredPhrase('Show 42 books',['Show {v0} books']),{source:'Show {v0} books',values:['42']});
 assert.equal(matchAuthoredPhrase('Private Person',['Search books']),undefined);
 assert.deepEqual(matchAuthoredPhrase('Open [item] 5?',['Open [item] {v0}?']),{source:'Open [item] {v0}?',values:['5']});
});

test('attribute templates localize their captions without cataloging private values',()=>{
 const result=compile('<button aria-label={`Copies of ${book.title}`} title={`View ${book.title}`}>{book.title}</button>','page.tsx');
 assert.deepEqual(Object.values(result.messages),['Copies of {v0}','View {v0}']);
 assert.match(result.code,/translationTemplates/);assert.match(result.code,/values: \[book.title\]/);
 assert.match(result.code,/\{book.title\}/);
});

test('fragment-based labels translate entire singular and plural phrases',()=>{
 const result=compile("const label=count===1?<>{`Show ${count} book`}</>:<>{`Show ${count} books`}</>;",'page.tsx');
 for(const phrase of ['Show {v0} book','Show {v0} books'])assert.equal(result.messages[textKey(phrase)],phrase);
});

test('conditional accessibility labels translate without changing option values',()=>{
 const result=compile(`<button aria-label={open ? 'Close book' : 'Open book'} title={saved ? 'In cart' : 'Add to cart'} onClick={save}>Save</button>`,'page.tsx');
 for(const phrase of ['Close book','Open book','In cart','Add to cart'])assert.equal(result.messages[textKey(phrase)],phrase);
 assert.match(result.code,/translationAttributes/);assert.match(result.code,/onClick=\{save\}/);
});

test('conditional, logical and mapped JSX translate every nested interface phrase',()=>{
 const result=compile(`export default () => <div>{failed ? <p>Try fewer filters.</p> : <section><h2>Address your parcel.</h2>{ready && <button>Continue</button>}{items.map(item => <span title="Open item">{item.name} Details</span>)}</section>}</div>`,'page.tsx');
 for(const phrase of ['Try fewer filters.','Address your parcel.','Continue','Open item',' Details'])assert.equal(result.messages[textKey(phrase)],phrase);
 assert.match(result.code,/\{item.name\}/);
 assert.ok(!Object.values(result.messages).includes('item.name'));
});

test('server catalog refreshes when development discovers new interface phrases',async t=>{
 const environment=process.env.NODE_ENV;
 process.env.NODE_ENV='development';
 t.after(()=>{if(environment===undefined)delete process.env.NODE_ENV;else process.env.NODE_ENV=environment;});
 const fs=require('node:fs'),path=require('node:path'),ts=require('typescript'),Module=require('node:module');
 let manifest=JSON.stringify({[textKey('First')]: 'First'}),calls=0;
 const file=path.join(__dirname,'server.ts'),compiledModule=new Module(file,module);
 compiledModule.filename=file;compiledModule.paths=Module._nodeModulePaths(__dirname);
 const original=compiledModule.require.bind(compiledModule);
 compiledModule.require=id=>id==='server-only'?{}:id==='next/headers'?{}:id==='next/cache'?{unstable_cache:fn=>fn}:id==='node:fs'?{readFileSync:()=>manifest}:id==='./catalog.cjs'?{prepareCatalog:async(_root,_locale,source)=>{calls++;return source;}}:original(id);
 compiledModule._compile(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,esModuleInterop:true}}).outputText,file);
 const {getInterfaceCatalog}=compiledModule.exports;
 const first=getInterfaceCatalog('es');assert.equal(getInterfaceCatalog('es'),first);await first;
 manifest=JSON.stringify({[textKey('First')]:'First',[textKey('New checkout label')]:'New checkout label'});
 const updated=await getInterfaceCatalog('es');
 assert.equal(updated[textKey('New checkout label')],'New checkout label');assert.equal(calls,2);
});
test('interpolation-only phrases preserve values without requesting translation',async()=>{
 const phrase='{v0}{v1}',source={[textKey(phrase)]:phrase};
 const service=createService({source,fetch:async()=>{throw Error('Must not contact provider');}});
 assert.equal((await service({language:'sr',ids:Object.keys(source)}))[textKey(phrase)],phrase);
});
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
 const mapped=compile("const options=[{label:'Newest'}];const page=<select>{options.map(({label})=><option key={label}>{label}</option>)}</select>;",'page.tsx');
 assert.match(mapped.code,/<option key=\{label\} value=\{label\}/);
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
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {readCatalog,prepareCatalog}=require('./catalog.cjs');
const {detectHeaderLocale}=require('./core.cjs');
test('request language respects quality, aliases and excluded languages',()=>{
 assert.equal(detectHeaderLocale('en;q=0,de-DE;q=0.8,ru;q=1'),'ru');
 assert.equal(detectHeaderLocale('xx,ar-SA;q=0.4'),'ar');
 assert.equal(detectHeaderLocale('en;q=0,xx;q=1'),'en');
});
test('complete catalogs reuse translations and generate only new authored text',async()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'interface-catalog-'));
 try {
  const first='Hello {v0}',second='Welcome';let calls=0;
  const source={[textKey(first)]:first};
  const translate=async({ids})=>{calls++;return Object.fromEntries(ids.map(id=>[id,id===textKey(first)?'Hallo {v0}':'Willkommen']));};
  const catalog=await prepareCatalog(root,'de',source,{translate});
  assert.equal(catalog[textKey(first)],'Hallo {v0}');
  await prepareCatalog(root,'de',source,{translate});assert.equal(calls,1);
  source[textKey(second)]=second;
  await prepareCatalog(root,'de',source,{translate});assert.equal(calls,2);
  assert.equal(Object.keys(readCatalog(root,'de',source)).length,2);
 } finally {fs.rmSync(root,{recursive:true,force:true});}
});
test('failed generation cannot publish a partial or stale catalog',async()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'interface-catalog-'));
 try {
  const source={[textKey('Hello')]: 'Hello'};
  const file=path.join(root,'messages','automatic','de.json');
  await assert.rejects(prepareCatalog(root,'de',source,{translate:async()=>({})}),/Incomplete/);
  assert.equal(fs.existsSync(file),false);
  fs.mkdirSync(path.dirname(file),{recursive:true});
  fs.writeFileSync(file,JSON.stringify({[textKey('Hello')]:{source:'Different',translation:'Hallo'}}));
  assert.deepEqual(readCatalog(root,'de',source),{});
 } finally {fs.rmSync(root,{recursive:true,force:true});}
});
test('the first server render includes localized text and interpolation values',()=>{
 const ts=require('typescript'),React=require('react'),{renderToString}=require('react-dom/server');
 const Module=require('node:module');
 const file=path.join(__dirname,'client.tsx');
 const compiled=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{jsx:ts.JsxEmit.ReactJSX,module:ts.ModuleKind.CommonJS,esModuleInterop:true}}).outputText;
 const compiledModule=new Module(file,module);compiledModule.filename=file;compiledModule.paths=Module._nodeModulePaths(__dirname);compiledModule._compile(compiled,file);
 const {AutomaticTranslationProvider,AutoText}=compiledModule.exports;
 const phrase='Hello {v0}';
 const html=renderToString(React.createElement(AutomaticTranslationProvider,{initial:{language:'de',catalog:{[textKey(phrase)]:'Hallo {v0}'}}},React.createElement(AutoText,{source:phrase,values:['Private Person']})));
 assert.ok(html.includes('Hallo'));assert.ok(html.includes('Private Person'));assert.ok(!html.includes('Hello'));
 const helper='Show {v0} books';
 const inferred=renderToString(React.createElement(AutomaticTranslationProvider,{initial:{language:'de',catalog:{[textKey(helper)]:'{v0} Bücher anzeigen'}}},React.createElement(AutoText,{source:'Show 42 books',candidates:[helper]})));
 assert.ok(inferred.includes('Bücher anzeigen'));assert.ok(inferred.includes('42'));assert.ok(!inferred.includes('Show'));
});
test('legacy manual preferences migrate before paint without reload loops',()=>{
 const ts=require('typescript'),Module=require('node:module'),vm=require('node:vm');
 const file=path.join(__dirname,'server.ts'),compiledModule=new Module(file,module);
 compiledModule.filename=file;compiledModule.paths=Module._nodeModulePaths(__dirname);
 const original=compiledModule.require.bind(compiledModule);
 compiledModule.require=id=>id==='server-only'?{}:id==='next/headers'?{}:id==='next/cache'?{unstable_cache:fn=>fn}:original(id);
 compiledModule._compile(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,esModuleInterop:true}}).outputText,file);
 const script=compiledModule.exports.manualLanguageBootstrap('language','UI_LANGUAGE');
 let cookie='',reloads=0;
 const document={get cookie(){return cookie;},set cookie(value){cookie=value.split(';')[0];}};
 const context={document,localStorage:{getItem:()=> 'de'},location:{reload:()=>reloads++}};
 vm.runInNewContext(script,context);assert.equal(cookie,'UI_LANGUAGE=de');assert.equal(reloads,1);
 vm.runInNewContext(script,context);assert.equal(reloads,1);
 vm.runInNewContext(script,{...context,document:{get cookie(){return '';},set cookie(_){} }});assert.equal(reloads,1);
 const automatic=compiledModule.exports.manualLanguageBootstrap('language','UI_LANGUAGE','auto');
 cookie='UI_LANGUAGE=de';context.localStorage.getItem=()=> 'auto';vm.runInNewContext(automatic,context);assert.equal(cookie,'UI_LANGUAGE=');assert.equal(reloads,2);
});

function sharedRoutingModule(){
 const ts=require('typescript'),Module=require('node:module');
 const file=path.join(__dirname,'../next.config.shared.ts'),loaded=new Module(file,module);
 loaded.filename=file;loaded.paths=Module._nodeModulePaths(__dirname);
 const original=loaded.require.bind(loaded);
 loaded.require=id=>id==='./localization/prepare.cjs'?{prepare:()=>{},verify:()=>{}}:original(id);
 loaded._compile(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020,esModuleInterop:true}}).outputText,file);
 return loaded.exports;
}
test('development origins use the canonical domain independently of resource names',()=>{
 const routing=sharedRoutingModule(),before={...process.env};
 try{
  process.env.DEV_HOST='dev.example.com';process.env.PROJECT_HOST='legacyresources';
  process.env.NEXT_PUBLIC_URL='https://dev.example.com';
  process.env.CLOUDFLARE_TUNNEL_URL='https://public.example.net';
  assert.deepEqual(routing.buildAllowedDevOrigins(),['*.trycloudflare.com','dev.example.com','public.example.net']);
  delete process.env.DEV_HOST;delete process.env.NEXT_PUBLIC_URL;delete process.env.CLOUDFLARE_TUNNEL_URL;
  assert.deepEqual(routing.buildAllowedDevOrigins(),['*.trycloudflare.com']);
 }finally{process.env=before;}
});

test('admin proxy is project-independent and preserves custom rewrites',async()=>{
 const routing=sharedRoutingModule(),before={...process.env};
 try{
  process.env.BACKEND_URL='https://backend.example.test';process.env.NEXT_PUBLIC_API_URL='/api';
  const custom={source:'/custom',destination:'/other'};
  const config=routing.withSharedDevConfig({rewrites:async()=>[custom]});
  const rules=await config.rewrites();assert.deepEqual(rules.afterFiles,[custom]);
  assert.equal(rules.beforeFiles[0].destination,'https://backend.example.test/admin/');
  assert.equal(rules.beforeFiles[1].destination,'https://backend.example.test/admin/:path+/');
  assert.equal(rules.beforeFiles[2].destination,'https://backend.example.test/static/:path*');
  delete process.env.BACKEND_URL;process.env.NEXT_PUBLIC_API_URL='https://second.example.test/api';
  assert.equal(routing.buildBackendRewrites()[0].destination,'https://second.example.test/admin/');
  process.env.NEXT_PUBLIC_API_URL='/api';assert.deepEqual(routing.buildBackendRewrites(),[]);
 }finally{process.env=before;}
});
test('admin slashes are exempt from frontend canonicalization',()=>{
 const routing=sharedRoutingModule();
 for(const trailing of [false,true]){
  const rules=routing.buildBackendRedirects(trailing);assert.equal(rules[0].destination,'/admin/');
  const exact=require('next/dist/compiled/path-to-regexp').pathToRegexp(rules[0].source);
  assert.equal(exact.test('/admin'),true);assert.equal(exact.test('/admin/'),false);
  const pattern=trailing?rules[2].source:rules[1].source;
  const regex=new RegExp('^'+pattern.slice(pattern.indexOf('(')+1,pattern.lastIndexOf(')'))+'$');
  for(const path of ['admin','admin/login','admin/mailroom/receivedemail','static/admin/css/base.css','media/file.png'])assert.equal(regex.test(path),false,path);
  assert.equal(regex.test('checkout'),true);
 }
 assert.equal(routing.buildBackendRedirects(false,true).length,1);
});

test('compiled Next.js redirects reach a stable URL in at most one hop',async()=>{
 const {unstable_getResponseFromNextConfig:request}=require('next/experimental/testing/server');
 const routing=sharedRoutingModule();
 for(const trailingSlash of [false,true]){
  for(const basePath of ['', '/portal']){
   const nextConfig=routing.withSharedDevConfig({basePath,trailingSlash});
   const cases=[['/',null],['/admin','/admin/'],['/admin/',null],
    ['/admin/login/',null],['/static/admin/css/base.css',null],['/media/photo.png',null],
    ['/.well-known/acme-challenge/token',null],['/.well-known/acme-challenge/token/',null],
    ['/favicon.ico',null],['/favicon.ico/','/favicon.ico']];
   for(const page of ['/games','/games/exile','/login','/api/session','/version/1.2/settings']){
    cases.push([page,trailingSlash?`${page}/`:null],[`${page}/`,trailingSlash?null:page]);
   }
   for(const [source,destination] of cases){
    const url=`https://example.test${basePath}${source}?next=%2Fgames%2F&lang=es`;
    const response=await request({url,nextConfig});
    const location=response.headers.get('location');
    assert.equal(location,destination?new URL(`${basePath}${destination}?next=%2Fgames%2F&lang=es`,url).href:null,
     `trailingSlash=${trailingSlash} ${url}`);
    if(location){
     assert.notEqual(location,url,'a redirect must not target its own URL');
     const canonical=await request({url:location,nextConfig});
     assert.equal(canonical.headers.get('location'),null,`canonical URL must be stable: ${location}`);
    }
   }
  }
 }
});
