const ts=require('typescript'),path=require('node:path');
const {textKey}=require('./core.cjs');
const attributes=new Set(['title','placeholder','alt','aria-label','aria-description']);
const ignoredTags=new Set(['script','style','code','pre','svg','math','textarea']);
const decoded=new Map();
function decode(text){
 if(!text.includes('&'))return text;
 if(decoded.has(text))return decoded.get(text);
 // Let the same TypeScript JSX parser decode the full HTML entity set.
 const output=ts.transpileModule(`const value=<p>${text}</p>;`,{compilerOptions:{jsx:ts.JsxEmit.React,target:ts.ScriptTarget.ESNext}}).outputText;
 const tree=ts.createSourceFile('decoded.js',output,ts.ScriptTarget.Latest,true);
 const value=tree.statements[0].declarationList.declarations[0].initializer.arguments[2]?.text??text;
 decoded.set(text,value);return value;
}
function compile(source,filename,componentPath){
 const tree=ts.createSourceFile(filename,source,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX);
 const messages={};let changed=false;
 const preserve=new Set(require(path.join(process.cwd(),'package.json')).localization?.preserve??[]);
 const record=text=>{if(!/\p{L}/u.test(text)||preserve.has(text.trim()))return false;const id=textKey(text);if(messages[id]&&messages[id]!==text)throw Error('Translation key collision');messages[id]=text;return true;};
 const collect=node=>{
  if(ts.isStringLiteralLike(node))return record(node.text);
  if(ts.isConditionalExpression(node)){const left=collect(node.whenTrue),right=collect(node.whenFalse);return left||right;}
  if(ts.isParenthesizedExpression(node))return collect(node.expression);
  return false;
 };
 const catalogCalls=node=>{
  if(ts.isCallExpression(node)&&['t','translate'].includes(node.expression.getText(tree))&&node.arguments[0])collect(node.arguments[0]);
  ts.forEachChild(node,catalogCalls);
 };
 catalogCalls(tree);
 const factory=ts.factory;
 const textElement=(text,values)=>{
  if(!record(text))return undefined;changed=true;
  const props=[factory.createJsxAttribute(factory.createIdentifier('source'),factory.createStringLiteral(text))];
  if(values)props.push(factory.createJsxAttribute(factory.createIdentifier('values'),factory.createJsxExpression(undefined,factory.createArrayLiteralExpression(values))));
  return factory.createJsxSelfClosingElement(factory.createIdentifier('__SharedAutoText'),undefined,factory.createJsxAttributes(props));
 };
 const expression=(node,visit)=>{
  if(ts.isStringLiteralLike(node))return textElement(node.text)||node;
  if(ts.isConditionalExpression(node))return factory.updateConditionalExpression(node,node.condition,node.questionToken,expression(node.whenTrue,visit),node.colonToken,expression(node.whenFalse,visit));
  if(ts.isTemplateExpression(node)){
   let text=node.head.text;const values=[];
   for(const span of node.templateSpans){text+=`{v${values.length}}`+span.literal.text;values.push(span.expression);}
   return textElement(text,values)||node;
  }
  // Expressions may contain JSX in ternaries, logical branches and callbacks.
  // Visit those nodes without translating arbitrary application string data.
  return ts.visitNode(node,visit);
 };
 const transform=context=>{
    const localizeChild=child=>{
     if(ts.isJsxText(child)){
      const lines=child.text.split(/\r?\n/);const text=lines.length===1?child.text:lines.map((line,i)=>i===0?line.trimEnd():i===lines.length-1?line.trimStart():line.trim()).filter(Boolean).join(' ');
      return textElement(decode(text))||child;
     }
     if(ts.isJsxExpression(child)&&child.expression)return factory.updateJsxExpression(child,expression(child.expression,visit));
     return ts.visitNode(child,visit);
    };
  const visit=node=>{
   if(ts.isJsxFragment(node))return factory.updateJsxFragment(node,node.openingFragment,node.children.map(localizeChild),node.closingFragment);
   if(ts.isCallExpression(node)&&['t','translate'].includes(node.expression.getText(tree))&&node.arguments[0]&&ts.isStringLiteralLike(node.arguments[0]))record(node.arguments[0].text);
   if(ts.isJsxElement(node)||ts.isJsxSelfClosingElement(node)){
    const opening=ts.isJsxElement(node)?node.openingElement:node;
    const tag=opening.tagName.getText(tree);
    const skip=ignoredTags.has(tag)||opening.attributes.properties.some(p=>ts.isJsxAttribute(p)&&(p.name.getText(tree)==='data-no-translate'||p.name.getText(tree)==='contentEditable'||p.name.getText(tree)==='translate'&&p.initializer&&ts.isStringLiteral(p.initializer)&&p.initializer.text==='no'));
    if(skip)return node;
    const native=/^[a-z][a-z0-9-]*$/.test(tag);
    const keys=[],templates=[];
    for(const p of opening.attributes.properties)if(native&&ts.isJsxAttribute(p)&&attributes.has(p.name.getText(tree))&&p.initializer&&(ts.isStringLiteral(p.initializer)?record(decode(p.initializer.text)):ts.isJsxExpression(p.initializer)&&p.initializer.expression&&collect(p.initializer.expression)))keys.push(p.name.getText(tree));
    for(const p of opening.attributes.properties)if(native&&ts.isJsxAttribute(p)&&attributes.has(p.name.getText(tree))&&p.initializer&&ts.isJsxExpression(p.initializer)&&p.initializer.expression&&ts.isTemplateExpression(p.initializer.expression)){
     const template=p.initializer.expression,values=[];let text=template.head.text;
     for(const span of template.templateSpans){text+=`{v${values.length}}`+span.literal.text;values.push(span.expression);}
     if(record(text))templates.push({key:p.name.getText(tree),text,values});
    }
    const originalProps=opening.attributes.properties.map(p=>{
     const template=ts.isJsxAttribute(p)&&templates.find(item=>item.key===p.name.getText(tree));
     return template?factory.updateJsxAttribute(p,p.name,factory.createStringLiteral(template.text)):p;
    });
    if(tag==='option'&&ts.isJsxElement(node)&&!originalProps.some(p=>ts.isJsxAttribute(p)&&p.name.getText(tree)==='value')&&node.children.every(child=>ts.isJsxText(child))){
     originalProps.push(factory.createJsxAttribute(factory.createIdentifier('value'),factory.createStringLiteral(decode(node.children.map(child=>child.text).join('').trim()))));changed=true;
    }
    const wrapped=keys.length||templates.length;
    const additional=[factory.createJsxAttribute(factory.createIdentifier('as'),factory.createStringLiteral(tag)),factory.createJsxAttribute(factory.createIdentifier('translationAttributes'),factory.createJsxExpression(undefined,factory.createArrayLiteralExpression(keys.map(k=>factory.createStringLiteral(k)))))];
    if(templates.length)additional.push(factory.createJsxAttribute(factory.createIdentifier('translationTemplates'),factory.createJsxExpression(undefined,factory.createObjectLiteralExpression(templates.map(item=>factory.createPropertyAssignment(factory.createStringLiteral(item.key),factory.createObjectLiteralExpression([
     factory.createPropertyAssignment('source',factory.createStringLiteral(item.text)),factory.createPropertyAssignment('values',factory.createArrayLiteralExpression(item.values)),
    ])))))));
    const props=factory.createJsxAttributes(wrapped?[...originalProps,...additional]:originalProps);
    const name=wrapped?factory.createIdentifier('__SharedAutoElement'):opening.tagName;
    if(wrapped)changed=true;
    if(ts.isJsxSelfClosingElement(node))return factory.updateJsxSelfClosingElement(node,name,node.typeArguments,props);
    const children=node.children.map(localizeChild);
    return factory.updateJsxElement(node,factory.updateJsxOpeningElement(opening,name,opening.typeArguments,props),children,factory.updateJsxClosingElement(node.closingElement,name));
   }
   return ts.visitEachChild(node,visit,context);
  };
  return node=>ts.visitNode(node,visit);
 };
 const result=ts.transform(tree,[transform]);let output=tree;
 if(changed){
  const reference=componentPath??path.join(__dirname,'client');
  const declaration=factory.createImportDeclaration(undefined,factory.createImportClause(false,undefined,factory.createNamedImports(['AutoText','AutoElement'].map(name=>factory.createImportSpecifier(false,factory.createIdentifier(name),factory.createIdentifier('__Shared'+name))))),factory.createStringLiteral(reference.replaceAll('\\','/')));
  const statements=[...result.transformed[0].statements];let index=0;
  while(index<statements.length&&ts.isExpressionStatement(statements[index])&&ts.isStringLiteral(statements[index].expression))index++;
  statements.splice(index,0,declaration);output=factory.updateSourceFile(result.transformed[0],statements);
 }
 const code=changed?ts.createPrinter({newLine:ts.NewLineKind.LineFeed}).printFile(output):source;
 result.dispose();return {code,messages};
}
module.exports={compile};
