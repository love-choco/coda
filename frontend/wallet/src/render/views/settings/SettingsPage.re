open Tc;

module Styles = {
  open Css;

  let headerContainer =
    style([display(`flex), justifyContent(`spaceBetween)]);

  let versionText =
    merge([
      Theme.Text.Header.h6,
      style([
        display(`flex),
        textTransform(`uppercase),
        paddingTop(`rem(0.5)),
      ]),
    ]);

  let container =
    style([
      height(`percent(100.)),
      padding(`rem(2.)),
      borderTop(`px(1), `solid, white),
      borderLeft(`px(1), `solid, white),
    ]);

  let label =
    merge([
      Theme.Text.Header.h3,
      style([
        margin2(~v=`rem(0.5), ~h=`zero),
        color(Theme.Colors.midnight),
        userSelect(`none),
      ]),
    ]);

  let walletItemContainer =
    style([
      display(`flex),
      flexDirection(`column),
      backgroundColor(`rgba((255, 255, 255, 0.8))),
      borderRadius(`px(6)),
      border(`px(1), `solid, Theme.Colors.slateAlpha(0.4)),
      width(`rem(28.)),
    ]);

  let walletItem =
    merge([
      Theme.Text.Body.regular,
      style([
        userSelect(`none),
        padding(`rem(1.)),
        color(Theme.Colors.midnight),
        display(`flex),
        alignItems(`center),
        borderBottom(`px(1), `solid, Theme.Colors.slateAlpha(0.25)),
        lastChild([borderBottomWidth(`zero)]),
        hover([
          backgroundColor(Theme.Colors.midnightAlpha(0.05)),
          selector("> :last-child", [color(Theme.Colors.hyperlink)]),
        ]),
      ]),
    ]);

  let walletName = style([width(`rem(12.5))]);

  let walletChevron =
    style([display(`inlineFlex), color(Theme.Colors.tealAlpha(0.5))]);
};

module SettingsQueryString = [%graphql
  {|
    query getSettings {
      version
      ownedWallets {
        publicKey @bsDecoder(fn: "Apollo.Decoders.publicKey")
      }
    }
  |}
];

module SettingsQuery = ReasonApollo.CreateQuery(SettingsQueryString);

module WalletSettingsItem = {
  [@react.component]
  let make = (~publicKey) => {
    let keyStr = PublicKey.toString(publicKey);
    let route = "/settings/" ++ Js.Global.encodeURIComponent(keyStr);
    <div
      className=Styles.walletItem
      onClick={_ => ReasonReact.Router.push(route)}>
      <div className=Styles.walletName> <WalletName pubkey=publicKey /> </div>
      <span className=Theme.Text.Body.mono>
        <Pill> {React.string(PublicKey.prettyPrint(publicKey))} </Pill>
      </span>
      <Spacer width=5.0 />
      <span className=Styles.walletChevron>
        <Icon kind=Icon.EmptyChevronRight />
      </span>
    </div>;
  };
};

[@react.component]
let make = () => {
  <SettingsQuery>
    {response =>
       switch (response.result) {
       | Loading => React.string("...")
       | Error(err) => React.string(err##message)
       | Data(data) =>
         let versionText =
           data##version
           |> Option.map(~f=version =>
                String.slice(
                  version,
                  ~from=0,
                  ~to_=min(8, String.length(version)),
                )
              )
           |> Option.withDefault(~default="Unknown");
         <div className=Styles.container>
           <div className=Styles.headerContainer>
             <div className=Theme.Text.Header.h3>
               {React.string("Node Settings")}
             </div>
             <div className=Styles.versionText>
               <span
                 className=Css.(
                   style([color(Theme.Colors.slateAlpha(0.3))])
                 )>
                 {React.string("Version:")}
               </span>
               <Spacer width=0.5 />
               <span
                 className=Css.(
                   style([color(Theme.Colors.slateAlpha(0.7))])
                 )>
                 {React.string(versionText)}
               </span>
             </div>
           </div>
           <Spacer height=1. />
           <NetworkDropdown />
           <Spacer height=1. />
           <div className=Styles.label>
             {React.string("Wallet Settings")}
           </div>
           <Spacer height=0.5 />
           <div className=Styles.walletItemContainer>
             {data##ownedWallets
              |> Array.map(~f=w =>
                   <WalletSettingsItem
                     key={PublicKey.toString(w##publicKey)}
                     publicKey=w##publicKey
                   />
                 )
              |> React.array}
           </div>
         </div>;
       }}
  </SettingsQuery>;
};