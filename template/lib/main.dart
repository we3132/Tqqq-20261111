import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const TqqqApp());

class TqqqApp extends StatelessWidget {
  const TqqqApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'TQsignal V2', debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF2563EB), scaffoldBackgroundColor: const Color(0xFFF5F7FA)),
    home: const Dashboard(),
  );
}

class Bar {
  final DateTime date;
  final double close, open;
  const Bar(this.date, this.close, this.open);
}

class DaySignal {
  final DateTime date;
  final String action, reason;
  final double qqq, ema20, ema60, ema200, tqqq;
  const DaySignal(this.date, this.action, this.reason, this.qqq, this.ema20, this.ema60, this.ema200, this.tqqq);
}

String day(DateTime d) => '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';
String money(double v, {int digits=2}) => v.toStringAsFixed(digits);

Future<List<Bar>> loadBars(String ticker) async {
  final uri = Uri.parse('https://query1.finance.yahoo.com/v8/finance/chart/$ticker?range=10y&interval=1d');
  final res = await http.get(uri, headers: {'User-Agent':'Mozilla/5.0'}).timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) throw Exception('$ticker 시세 응답 ${res.statusCode}');
  final root = jsonDecode(res.body) as Map<String,dynamic>;
  final result = (root['chart']['result'] as List).first;
  final stamps = (result['timestamp'] as List?) ?? [];
  final quote = result['indicators']['quote'][0];
  final closes = quote['close'] as List;
  final opens = quote['open'] as List;
  final out = <Bar>[];
  for (var i=0; i<stamps.length; i++) {
    final c = (closes[i] as num?)?.toDouble();
    final o = (opens[i] as num?)?.toDouble();
    if (c == null || o == null || c <= 0 || o <= 0) continue;
    // US trading dates are based on New York exchange local dates, not device time.
    final dt = DateTime.fromMillisecondsSinceEpoch((stamps[i] as num).toInt()*1000, isUtc:true);
    out.add(Bar(DateTime.utc(dt.year,dt.month,dt.day),c,o));
  }
  return out;
}

// Strategy V2: legacy QQQ entry/exit plus high-volatility protective exit.
// All signals use completed daily bars. Execution is NOT automated.
List<DaySignal> signals(List<Bar> q, List<Bar> t, {int cooldownDays=3, bool requireUpDay=true, bool enableOverlay=true}) {
  final tByDate = {for (final b in t) day(b.date): b};
  double? e20, e60, e200;
  bool legacyHolding=false, actualHolding=false, previousBuyReady=false;
  bool overlayExited=false, trailArmed=false;
  int under60=0, cooldownUntilIndex=-1;
  double entry=0, peak=0;
  final ret=<DaySignal>[];
  final closes=<double>[];
  int tradeIndex=0;
  for (final b in q) {
    closes.add(b.close);
    e20=e20==null?b.close:e20+(2/21)*(b.close-e20);
    e60=e60==null?b.close:e60+(2/61)*(b.close-e60);
    e200=e200==null?b.close:e200+(2/201)*(b.close-e200);
    final tb=tByDate[day(b.date)];
    if(tb==null || closes.length<200) continue;
    final riskOn=b.close>e200;
    final ready=riskOn && b.close>e20 && b.close>e60;
    under60=b.close<e60?under60+1:0;
    final ret5=closes.length>5?b.close/closes[closes.length-6]-1:0.0;
    double vol=0;
    if(closes.length>=22) {
      final r=<double>[];
      for(var k=closes.length-20;k<closes.length;k++) {r.add(closes[k]/closes[k-1]-1);}
      final mean=r.reduce((a,b)=>a+b)/r.length;
      vol=math.sqrt(r.map((x)=>(x-mean)*(x-mean)).reduce((a,b)=>a+b)/r.length)*math.sqrt(252);
    }
    final legacySell=under60>=2 || (ret5<=-0.06 && b.close<e60);
    final legacyBuy=!legacyHolding && ready && !previousBuyReady;
    if(legacyHolding && legacySell) legacyHolding=false;
    else if(legacyBuy) legacyHolding=true;
    String action='WAIT', reason='기존 매수 신호 대기';
    if(actualHolding) {
      peak=math.max(peak,tb.close);
      if(tb.close>=entry*1.05) trailArmed=true;
      final protectiveSell=enableOverlay && vol>=0.28 && trailArmed && tb.close<=peak*0.97;
      if(legacySell) {
        action='SELL'; reason='기존 QQQ 매도 신호'; actualHolding=false;
        overlayExited=false;trailArmed=false;
      } else if(protectiveSell) {
        action='SELL'; reason='고변동성 보호매도: 최고 종가 대비 -3%';
        actualHolding=false;overlayExited=true;trailArmed=false;
        // The first eligible re-entry signal is after N full subsequent trading bars.
        cooldownUntilIndex=tradeIndex+cooldownDays+1;
      } else {action='HOLD';reason=vol>=0.28?'고변동성: 보호매도 감시':'기존 포지션 유지';}
    } else if(legacyBuy) {
      action='BUY';reason='기존 QQQ 신규 매수 신호';
      actualHolding=true;overlayExited=false;entry=tb.close;peak=tb.close;trailArmed=false;
    } else if(overlayExited && legacyHolding) {
      final cooled=tradeIndex>=cooldownUntilIndex;
      final up=closes.length>=2 && b.close>closes[closes.length-2];
      if(cooled && (!requireUpDay || up)) {
        action='BUY';reason='보호매도 후 ${cooldownDays}거래일 쿨다운 재진입';
        actualHolding=true;overlayExited=false;entry=tb.close;peak=tb.close;trailArmed=false;
      } else {reason=cooled?'QQQ 상승 확인 대기':'보호매도 후 쿨다운 진행 중';}
    } else if(overlayExited && !legacyHolding) {
      overlayExited=false;reason='기존 전략이 매수 상태가 아니므로 재진입 보류';
    } else if(legacyHolding) {reason='기존 매수 상태와 실제 포지션 동기화 대기';}
    previousBuyReady=ready;
    ret.add(DaySignal(b.date,action,reason,b.close,e20,e60,e200,tb.close));
    tradeIndex++;
  }
  return ret.reversed.toList();
}

class Dashboard extends StatefulWidget {const Dashboard({super.key}); @override State<Dashboard> createState()=>_DashboardState();}
class _DashboardState extends State<Dashboard> {
  int tab=0; String historyPeriod='1년', historyFilter='전체'; int historyLimit=60; int cooldownDays=3; bool requireUpDay=true, enableOverlay=true; bool krw=false, notifications=true, buyAlert=true, sellAlert=true, riskAlert=true;
  double fx=0, initial=0, cash=0; String fxStamp='조회 전', error='';
  List<DaySignal> history=[];
  List<Map<String,dynamic>> flows=[]; // {date, kind, usd}; deposits positive, withdrawals negative
  List<Map<String,dynamic>> settlements=[]; // {date, price, shares, balance, prior, netFlow}
  final amount=TextEditingController(), price=TextEditingController(), shares=TextEditingController();
  bool busy=false;
  @override void initState(){super.initState(); _load(); refresh();}
  @override void dispose(){amount.dispose();price.dispose();shares.dispose();super.dispose();}
  Future<void> _load() async {
    final p=await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      cooldownDays=p.getInt('cooldownDays')??3; requireUpDay=p.getBool('requireUpDay')??true; enableOverlay=p.getBool('enableOverlay')??true; initial=p.getDouble('initial')??0; cash=p.getDouble('cash')??0;
      krw=p.getBool('krw')??false;notifications=p.getBool('notifications')??true;
      buyAlert=p.getBool('buyAlert')??true;sellAlert=p.getBool('sellAlert')??true;riskAlert=p.getBool('riskAlert')??true;
      fx=p.getDouble('fx')??0;fxStamp=p.getString('fxStamp')??'조회 전';
      flows=(jsonDecode(p.getString('flows')??'[]') as List).map((e)=>Map<String,dynamic>.from(e)).toList();
      settlements=(jsonDecode(p.getString('settlements')??'[]') as List).map((e)=>Map<String,dynamic>.from(e)).toList();
    });
  }
  Future<void> _save() async {
    final p=await SharedPreferences.getInstance();
    await p.setInt('cooldownDays',cooldownDays);await p.setBool('requireUpDay',requireUpDay);await p.setBool('enableOverlay',enableOverlay);await p.setDouble('initial',initial);await p.setDouble('cash',cash);
    await p.setBool('krw',krw);await p.setBool('notifications',notifications);
    await p.setBool('buyAlert',buyAlert);await p.setBool('sellAlert',sellAlert);await p.setBool('riskAlert',riskAlert);
    await p.setDouble('fx',fx);await p.setString('fxStamp',fxStamp);
    await p.setString('flows',jsonEncode(flows));await p.setString('settlements',jsonEncode(settlements));
  }
  Future<void> refresh() async {
    if (busy) return;
    setState(()=>busy=true);
    try {
      final bars=await Future.wait([loadBars('QQQ'),loadBars('TQQQ')]);
      final s=signals(bars[0],bars[1],cooldownDays:cooldownDays,requireUpDay:requireUpDay,enableOverlay:enableOverlay);
      if (!mounted) return;
      setState(() {history=s;error='';});
    } catch(e) {if(mounted)setState(()=>error='시세 갱신 실패: $e');}
    try {
      final response=await http.get(Uri.parse('https://open.er-api.com/v6/latest/USD')).timeout(const Duration(seconds:10));
      if(response.statusCode!=200)throw Exception('환율 응답 오류');
      final data=jsonDecode(response.body);
      final rate=(data['rates']['KRW'] as num?)?.toDouble();
      if(rate==null||rate<=0)throw Exception('환율 데이터 없음');
      if(mounted){setState(() {fx=rate;fxStamp=DateTime.now().toLocal().toString().substring(0,16);});await _save();}
    } catch (_) {if(mounted && fx==0) setState(()=>fxStamp='환율 조회 실패');}
    if(mounted)setState(()=>busy=false);
  }
  double get deposits => initial+flows.where((e)=>e['kind']=='입금').fold<double>(0,(a,e)=>a+(e['usd'] as num).toDouble());
  double get withdrawals => flows.where((e)=>e['kind']=='출금').fold<double>(0,(a,e)=>a+(e['usd'] as num).toDouble());
  double get netProfit => cash+withdrawals-deposits;
  String fmt(double usd) => krw && fx>0?'₩${(usd*fx).round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'),(m)=>',')}':'\$${money(usd)}';
  Widget panel(Widget child)=>Card(color:Colors.white,elevation:0,margin:const EdgeInsets.only(bottom:12),child:Padding(padding:const EdgeInsets.all(18),child:child));
  Widget heading(String s)=>Padding(padding:const EdgeInsets.only(bottom:12),child:Text(s,style:const TextStyle(fontWeight:FontWeight.w700,fontSize:19)));
  Widget row(String a,String b)=>Padding(padding:const EdgeInsets.symmetric(vertical:6),child:Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[Flexible(child:Text(a)),Text(b,style:const TextStyle(fontWeight:FontWeight.w600))]));
  void snack(String s)=>ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s)));
  Future<void> setInitial() async {
    final v=double.tryParse(amount.text);
    if(v==null||v<=0){snack('0보다 큰 달러 금액을 입력해 주세요.');return;}
    if(initial>0||settlements.isNotEmpty){snack('최초 투자금은 한 번만 등록합니다. 이후에는 추가 입금을 이용하세요.');return;}
    setState(() {initial=v;cash=v;});await _save();amount.clear();if(mounted)Navigator.pop(context);
  }
  Future<void> addFlow(String kind) async {
    final v=double.tryParse(amount.text);
    if(v==null||v<=0){snack('올바른 달러 금액을 입력해 주세요.');return;}
    if(kind=='출금'&&v>cash){snack('현재 기록된 달러 잔고보다 많이 출금할 수 없습니다.');return;}
    setState(() {flows.insert(0,{'date':DateTime.now().toIso8601String(),'kind':kind,'usd':v});cash+=kind=='입금'?v:-v;});
    await _save();amount.clear();if(mounted)Navigator.pop(context);
  }
  Future<void> addSettlement() async {
    final p=double.tryParse(price.text),q=double.tryParse(shares.text),v=double.tryParse(amount.text);
    if(p==null||p<=0||q==null||q<=0||v==null||v<0){snack('매도가·수량·매도 후 잔고를 확인해 주세요.');return;}
    final prior=cash;
    setState(() {settlements.insert(0,{'date':DateTime.now().toIso8601String(),'price':p,'shares':q,'balance':v,'prior':prior});cash=v;});
    await _save();price.clear();shares.clear();amount.clear();if(mounted)Navigator.pop(context);
  }
  void dialog(String kind) {
    amount.clear();price.clear();shares.clear();
    showDialog(context:context,builder:(ctx)=>AlertDialog(title:Text(kind=='최초'?'최초 투자금 (USD)':kind=='정산'?'매도 후 계좌 정산': '추가 $kind (USD)'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
      if(kind=='정산') ...[TextField(controller:price,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'실제 매도가 (USD)')),TextField(controller:shares,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'매도 수량 (주)'))],
      TextField(controller:amount,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:InputDecoration(labelText:kind=='정산'?'매도 후 총 달러 잔고 (USD)':'금액 (USD)')),
      if(kind=='정산')const Padding(padding:EdgeInsets.only(top:12),child:Text('이전 정산 이후 추가 입출금이 있으면 자동으로 별도 기록됩니다. 실제 계좌에 다른 보유 주식이 있다면 잔고 방식은 적합하지 않습니다.',style:TextStyle(fontSize:12)))
    ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('취소')),FilledButton(onPressed:()=>kind=='최초'?setInitial():kind=='정산'?addSettlement():addFlow(kind),child:const Text('저장'))]));
  }
  Widget home() {
    final s=history.isEmpty?null:history.first;
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[heading('현재 신호'),panel(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(s?.action??'미확인',style:TextStyle(fontSize:40,fontWeight:FontWeight.w800,color:s?.action=='BUY'?Colors.green:s?.action=='SELL'?Colors.red:Colors.blueGrey)),
      Text(s==null?'시세를 불러오지 못했습니다.': '${day(s.date)} 미국장 종가 기준'),const SizedBox(height:8),Text(s?.reason??error),
      const SizedBox(height:12),const Text('신호는 장 마감 후 확정됩니다. 다음 미국 거래일 시가에 가상 체결하는 전략이며 실제 주문은 실행하지 않습니다.',style:TextStyle(fontSize:12,color:Colors.black54))
    ])),heading('내 달러 자산'),panel(Column(children:[row('기록된 총 달러 잔고',fmt(cash)),row('총 입금액',fmt(deposits)),row('누적 출금액',fmt(withdrawals)),row('현금흐름 차감 순손익',fmt(netProfit))])),
    panel(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[row('원화 환산 환율',fx>0?'1 USD = ₩${money(fx)}':'조회 실패'),Text('마지막 환율 조회: $fxStamp',style:const TextStyle(fontSize:12,color:Colors.black54)),const Text('계좌 자산은 사용자가 입력한 잔고 기준입니다. 실시간 증권사 연동이 아닙니다.',style:TextStyle(fontSize:12,color:Colors.black54))]))]);
  }
  Widget historyPage()=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
  heading('전략 설정 · 보호매도'),
  SwitchListTile(title:const Text('고변동성 보호매도'),subtitle:const Text('QQQ 변동성 28% 이상 · +5% 활성화 · -3% 매도'),value:enableOverlay,onChanged:(v){setState(()=>enableOverlay=v);_save();refresh();}),
  Row(children:[const Text('쿨다운 (거래일)'),const SizedBox(width:12),DropdownButton<int>(value:cooldownDays,items:[2,3,5,10,15,20].map((v)=>DropdownMenuItem(value:v,child:Text('$v일'))).toList(),onChanged:(v){if(v!=null){setState(()=>cooldownDays=v);_save();refresh();}})]),
  SwitchListTile(title:const Text('재진입 시 QQQ 전일 상승 확인'),value:requireUpDay,onChanged:(v){setState(()=>requireUpDay=v);_save();refresh();}),
  const Text('종가 기준 신호이며 실제 주문은 실행되지 않습니다.'),
  heading('매매 히스토리'),
  Wrap(spacing:8,runSpacing:6,children:[
    for(final period in const ['1개월','1년','5년','10년'])
      ChoiceChip(label:Text(period),selected:historyPeriod==period,onSelected:(_){setState(() {historyPeriod=period;historyLimit=60;});}),
  ]),
  const SizedBox(height:8),
  Wrap(spacing:8,runSpacing:6,children:[
    for(final filter in const ['전체','BUY','SELL','HOLD','WAIT'])
      ChoiceChip(label:Text(filter),selected:historyFilter==filter,onSelected:(_){setState(() {historyFilter=filter;historyLimit=60;});}),
  ]),
  const SizedBox(height:8),
  Builder(builder:(context){
    if(history.isEmpty) return panel(Text(error.isEmpty?'데이터를 불러오는 중입니다.':error));
    final latest=history.first.date;
    final start=historyPeriod=='1개월'
      ? DateTime.utc(latest.year,latest.month-1,latest.day)
      : DateTime.utc(latest.year-(historyPeriod=='10년'?10:historyPeriod=='5년'?5:1),latest.month,latest.day);
    final matches=history.where((s)=>!s.date.isBefore(start) && (historyFilter=='전체'||s.action==historyFilter)).toList();
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('검색 결과 ${matches.length}건 · ${day(start)} ~ ${day(latest)}',style:const TextStyle(color:Colors.black54,fontSize:12)),
      const SizedBox(height:8),
      if(matches.isEmpty) panel(const Text('선택한 기간과 매매 유형에 해당하는 기록이 없습니다.')),
      for(final s in matches.take(historyLimit))
        panel(ExpansionTile(
          tilePadding:EdgeInsets.zero,
          title:Text('${day(s.date)}   ${s.action}',style:TextStyle(fontWeight:FontWeight.w700,color:s.action=='BUY'?Colors.green:s.action=='SELL'?Colors.red:null)),
          subtitle:Text(s.reason,maxLines:1,overflow:TextOverflow.ellipsis),
          children:[
            row('신호 유형',s.action),row('QQQ 종가','\$${money(s.qqq)}'),
            row('EMA20','\$${money(s.ema20)}'),row('EMA60','\$${money(s.ema60)}'),
            row('EMA200','\$${money(s.ema200)}'),row('TQQQ 종가','\$${money(s.tqqq)}'),
            const Text('신호일 종가 기준. 매수·매도 가상 체결은 다음 거래일 시가.',style:TextStyle(fontSize:11,color:Colors.black54)),
          ],
        )),
      if(matches.length>historyLimit)
        Center(child:OutlinedButton(onPressed:()=>setState(()=>historyLimit+=60),child:Text('60건 더 보기 (${matches.length-historyLimit}건 남음)'))),
    ]);
  }),
  ]);
  Widget performance()=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[heading('누적 성과'),panel(Column(children:[row('실제 계좌 기록 기준 순손익',fmt(netProfit)),row('총 입금',fmt(deposits)),row('총 출금',fmt(withdrawals)),row('기록된 현재 잔고',fmt(cash)),const SizedBox(height:8),const Text('단순 순손익 = 현재 자산 + 출금 - 입금. 추가 입금이 있는 경우 이 값은 수익률(%)이 아닙니다. 시간가중수익률은 일별 계좌 평가액이 있어야 계산할 수 있습니다.',style:TextStyle(fontSize:12,color:Colors.black54))])),
    heading('매도 정산 기록'),if(settlements.isEmpty)panel(const Text('아직 정산 기록이 없습니다.')), ...settlements.map((e)=>panel(Column(children:[row('정산 날짜',(e['date'] as String).substring(0,10)),row('매도가','\$${money((e['price'] as num).toDouble())}'),row('매도 수량','${e['shares']}주'),row('정산 후 잔고',fmt((e['balance'] as num).toDouble())),const Text('거래 손익은 별도의 매수 원가·잔여 현금 기록이 있어야 정확히 산출할 수 있습니다.',style:TextStyle(fontSize:12,color:Colors.black54))]))),
    heading('전략 모의 성과'),panel(const Text('신호 히스토리는 자동 조회됩니다. 첫 BUY 이후 다음 거래일 시가로 가상 체결하는 모의 포트폴리오 자동 계산은 다음 버전에서 연결됩니다. 현재 이 화면에 가상의 수익을 표시하지 않습니다.'))]);
  Widget manage()=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[heading('투자금 관리'),panel(Column(children:[row('최초 투자금',fmt(initial)),row('추가 입금 합계',fmt(deposits-initial)),row('누적 출금',fmt(withdrawals)),row('현재 기록 잔고',fmt(cash)),Wrap(spacing:8,runSpacing:8,children:[OutlinedButton(onPressed:initial==0?()=>dialog('최초'):null,child:const Text('최초 투자금')),OutlinedButton(onPressed:initial>0?()=>dialog('입금'):null,child:const Text('추가 입금')),OutlinedButton(onPressed:initial>0?()=>dialog('출금'):null,child:const Text('금액 회수')),FilledButton(onPressed:initial>0?()=>dialog('정산'):null,child:const Text('매도 정산'))])])),
    heading('입출금 기록'),if(flows.isEmpty)panel(const Text('입출금 내역이 없습니다.')),...flows.map((e)=>panel(row('${(e['date'] as String).substring(0,10)}  ${e['kind']}',fmt((e['usd'] as num).toDouble())))),
    heading('알림 설정'),panel(Column(children:[SwitchListTile(title:const Text('알림 사용'),value:notifications,onChanged:(v){setState(()=>notifications=v);_save();}),SwitchListTile(title:const Text('BUY 알림'),value:buyAlert,onChanged:(v){setState(()=>buyAlert=v);_save();}),SwitchListTile(title:const Text('SELL 알림'),value:sellAlert,onChanged:(v){setState(()=>sellAlert=v);_save();}),SwitchListTile(title:const Text('장중 위험 알림'),value:riskAlert,onChanged:(v){setState(()=>riskAlert=v);_save();}),const Text('현재 스위치는 설정 저장만 지원합니다. 앱이 종료된 상태에서의 푸시 알림은 서버 및 FCM 연동 전까지 제공되지 않습니다.',style:TextStyle(fontSize:12,color:Colors.black54))]))]);
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('TQsignal',style:TextStyle(fontWeight:FontWeight.w800)),actions:[TextButton(onPressed:(){setState(()=>krw=!krw);_save();},child:Text(krw?'KRW ▾':'USD ▾')),IconButton(onPressed:busy?null:refresh,icon:busy?const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.refresh))]),body:SafeArea(child:ListView(padding:const EdgeInsets.all(16),children:[if(error.isNotEmpty)Padding(padding:const EdgeInsets.only(bottom:8),child:Text(error,style:const TextStyle(color:Colors.red))),[home,historyPage,performance,manage][tab]() ])),bottomNavigationBar:NavigationBar(selectedIndex:tab,onDestinationSelected:(v)=>setState(()=>tab=v),destinations:const [NavigationDestination(icon:Icon(Icons.home_outlined),label:'홈'),NavigationDestination(icon:Icon(Icons.history),label:'히스토리'),NavigationDestination(icon:Icon(Icons.show_chart),label:'누적 성과'),NavigationDestination(icon:Icon(Icons.settings_outlined),label:'관리')]));
}
