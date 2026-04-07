import "@mantine/core/styles.css";
import "@mantine/dates/styles.css";
import { MantineProvider } from "@mantine/core";
import { DatesProvider } from "@mantine/dates";
import { MsalProvider } from "@azure/msal-react";
import { EventType, PublicClientApplication } from "@azure/msal-browser";
import dayjs from "dayjs";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import { msalConfig } from "./authConfig";

const msalInstance = new PublicClientApplication(msalConfig);

const accounts = msalInstance.getAllAccounts();
if (accounts.length > 0) {
  msalInstance.setActiveAccount(accounts[0]);
}

msalInstance.addEventCallback((event) => {
  if (event.eventType === EventType.LOGIN_SUCCESS && event.payload && "account" in event.payload) {
    const account = event.payload.account;
    if (account) {
      msalInstance.setActiveAccount(account);
    }
  }
});

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <MsalProvider instance={msalInstance}>
      <MantineProvider defaultColorScheme="light">
        <DatesProvider settings={{ locale: dayjs.locale(), firstDayOfWeek: 0 }}>
          <App />
        </DatesProvider>
      </MantineProvider>
    </MsalProvider>
  </StrictMode>
);
