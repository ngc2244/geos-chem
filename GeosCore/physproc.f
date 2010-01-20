! $Id: physproc.f,v 1.5 2010/01/20 19:31:58 ccarouge Exp $
      SUBROUTINE PHYSPROC( SUNCOS, SUNCOSB )
!
!******************************************************************************
!  Subroutine PHYSPROC is the driver for SMVGEAR II chemistry.  It calls both
!  CALCRATE to compute the rxn rates and the SMVGEAR solver routine.
!  (M. Jacobson 1993; bdf, bmy, 4/18/03, 9/29/03)
!
!  NOTES:
!  (1 ) For GEOS-CHEM we had to remove ABSHUM, AIRDENS, CSPEC, IXSAVE, IYSAVE,
!        and T3 from "comode.h" and to declare these allocatable in F90 module
!        "comode_mod.f".  This allows us to only allocate these if we are 
!        doing a fullchem run.  Now references TIMESTAMP_STRING from 
!        "time_mod.f".  Now pass SUNCOSB via the arg list.  Now force double
!        precision with the "D" exponent. (bmy, 4/18/03)
!  (2 ) Comment out section that computes photorates from original SMVGEAR II
!        file "photrate.dat"...this is not needed.  Remove TFROMID, it's not
!        used anywhere else.  Remove references to LASTCHEM, this is mpt 
!        initialized anywhere.  Now reference CSUMA, CSUMC, ERRMX2 from
!        "comode_mod.f". (bmy, 7/30/03)
!  (3 ) LINUX has a problem putting a function call w/in a WRITE statement.  
!        Now save output from TIMESTAMP_STRING to STAMP and print that.
!        (bmy, 9/29/03)
!  (4 ) Fixed case of small KULOOP (phs, 10/5/07)
!  (5 ) Now only get the rx rates if not using SMVGEAR (phs,ks,dhk, 09/15/09)
!  (6 ) Now calls KPP after calculating the reaction rates to save memory.
!       (ccc, 12/9/09)
!******************************************************************************
!
      ! References to F90 modules (bmy, 10/19/00)
      USE COMODE_MOD,      ONLY : ABSHUM, AIRDENS,  CSPEC,   CSUMA,  
     &                            CSUMC,  ERRMX2,  IXSAVE, 
     &                            IYSAVE, T3
!--- Previous to (ccc, 12/9/09)
!      USE GCKPP_COMODE_MOD,ONLY : R_KPP
      USE LOGICAL_MOD,     ONLY : LKPP
      USE TIME_MOD,        ONLY : TIMESTAMP_STRING
      USE CHEMISTRY_MOD,   ONLY : GCKPP_DRIVER
      USE GCKPP_GLOBAL,    ONLY : NTT
      
      IMPLICIT NONE

#     include "CMN_SIZE"  ! Size parameters
#     include "comode.h"  ! SMVGEAR II arrays
C
C *********************************************************************
C ************        WRITTEN BY MARK JACOBSON (1993)      ************
C ***             (C) COPYRIGHT, 1993 BY MARK Z. JACOBSON           *** 
C ***       U.S. COPYRIGHT OFFICE REGISTRATION NO. TXu 670-279      *** 
C ***                         (650) 723-6836                        *** 
C *********************************************************************
C
C PPPPPPP  H     H  Y     Y  SSSSSSS  PPPPPPP RRRRRRR  OOOOOOO  CCCCCCC
C P     P  H     H   Y   Y   S        P     P R     R  O     O  C 
C PPPPPPP  HHHHHHH     Y     SSSSSSS  PPPPPPP RRRRRRR  O     O  C 
C P        H     H     Y           S  P       R  R     O     O  C 
C P        H     H     Y     SSSSSSS  P       P    P   OOOOOOO  CCCCCCC
C
C *********************************************************************
C * THIS SUBROUTINE CALLS CALCRATE.F AND SMVGEAR.F. TO SOLVE GAS-     *
C * PHASE CHEMICAL EQUATIONS. THE ROUTINE DIVIDES THE GRID DOMAIN     *
C * INTO GRID BLOCKS, AND THE CODE VECTORIZES AROUND THE NUMBER OF    *
C * GRID CELLS IN EACH BLOCK.                                         *
C *                                                                   *
C *********************************************************************
C
C *********************************************************************
C ****************         UPDATE 24-HOUR CLOCK        ****************
C *********************************************************************
C CHEMINTV = TIME INTERVAL FOR CHEMISTRY
C IRCHEM   = COUNTS # CHEMINTV TIME-INTERVALS
C
      ! Arguments
      REAL*8, INTENT(IN) :: SUNCOS(MAXIJ), SUNCOSB(MAXIJ)
      
      ! Local variables
      INTEGER IDLAST,IMLAST,NMINADD,NHRADD,NDAYADD,NMONADD,NYEARAD
      INTEGER MLOOP,LOREORD,ILNCS,IHNCS,JLOOP,NBLOCKUSE,IAVBLOK,IAVGSIZE
      INTEGER JLOOPN,JOLD,JNEW,KLOOP,NSUNRISE,NSUNSET,JLOOPC,NNORISE
      INTEGER JLLAST,IT,IRADD,LVAL,IRVAL,IRADD1,JREORD,IPAR,JPAR,JPAR1
      INTEGER NSUMBLOCK,NCELLROW,NBLOCKROW,ICG,I,NGCOUNT,NGHI,IAVG
      INTEGER IREMAIN,IUSESIZE,NREBLOCK,L
      INTEGER IX,IY,IJWINDOW,KBLK2,NK

      INTEGER COUNTER,JGAS
      REAL*8 S1CON,S2CON,ARGS,CONSTQ,SNOON,CONTEMP,DIFCONC,PLODYN
      REAL*8 PR3,RIS,RST,TBEGIN,TFINISH,VALLOW,CLO1,CLO2,SUMFRACS
      REAL*8 SUMRMS,SUMHI,SUMRMSH,CMOD,CGOOD,FRACDIF,FRACABS,AVGERR
      REAL*8 RMSCUR,AVGHI,RMSCURH,FSTEPT,FITS,TSTEPIT,PHIDYN
      REAL*8 GMU

      INTEGER :: AS
      ! For LINUX fix (bmy, 9/29/03)
      CHARACTER(LEN=16) :: STAMP

      !=================================================================
      ! PHYSPROC begins here!
      !=================================================================
      IRCHEM  = IRCHEM + 1
      TIME    = TIME        + CHEMINTV
      TSPMIDC = MOD(TSPMIDC + CHEMINTV,SCDAY) 
      COUNTER = 0

      ! Return if we have turned off SMVGEAR
      IF (IFSOLVE.EQ.0) RETURN

      ! Echo timestamp
      STAMP = TIMESTAMP_STRING()
      WRITE( 6, 100 ) STAMP
 100  FORMAT( '     - PHYSPROC: Trop chemistry at ', a )
C                                                                       
C *********************************************************************
C *********************************************************************
C NCS       = 1..NCSGAS --> DO GAS CHEMISTRY
C LOREORD   = 1 IF REORDERING; = 2 IF NO REORDERING
C


      IF (IFREORD.EQ.1.AND.NTLOOP.GT.1) THEN
       LOREORD   = 1
      ELSE 
       LOREORD   = 2
      ENDIF 
C
      ILNCS      = 1
      IHNCS      = NCSGAS 
C
C *********************************************************************
C *         REORDER CELLS AND BLOCKS THEN SOLVE CHEMICAL ODES         *
C *********************************************************************
C ISREORD   = 1: THEN REORDER GRID CELLS AND GRID BLOCKS FOR CHEMISTY;
C           = 2: SOLVE CHEMISTRY 
C JREORDER  = GIVES ORIGINAL  GRID-CELL FROM RE-ORDERED GRID-CELL
C LREORDER  = JREORDER
C NBLOCKUSE = # OF ORIGINAL BLOCKS (ISREORD EQ LOREORD) OR
C             # OF BLOCKS AFTER REORDERING (ISREORD NE LOREORD)
C NCS       = 1..NCSGAS FOR GAS CHEMISTRY
C NCSP      = NCS       FOR DAYTIME   GAS CHEM
C           = NCS + ICS FOR NIGHTTIME GAS CHEM
C
      DO 860 NCS            = ILNCS, IHNCS
C
       DO 855 ISREORD       = LOREORD, 2
C
        !write(6,*) 'value of isreord= ',isreord
        IF (ISREORD.EQ.LOREORD) THEN
C
C *********************************************************************
C                   DETERMINE BLOCK SIZES FOR CHEMISTRY
C *********************************************************************
C                CHEMISTRY IN ONE REGION OF THE ATMOSPHERE
C *********************************************************************
C IGLOBCHEM = -2 --> SOLVE ALL GAS CHEMISTRY WITH COMBINATION OF U/R/S SETS
C           = -1 --> SOLVE ALL GAS CHEMISTRY WITH COMBINATION OF R/S SETS
C           = 0  --> SOLVE ALL GAS CHEMISTRY WITH EITHER U, R, OR S SETS
C           = 1  --> SOLVE EACH REGION SEPARATELY WITH U, R, OR S SET
C
          IF (IGLOBCHEM.LE.0) THEN
            !NTLOOPUSE           = NTLOOPNCS(NCS)

           ! updated ntloop calc in ruralbox.f
            NTLOOPUSE          = NTLOOP  
           DO 320 JLOOP        = 1, NTLOOPUSE
 320        JREORDER(JLOOP)    = JLOOP
C
          ELSE

C
C *********************************************************************
C        GLOBAL CHEMISTRY - ASSUME THREE REGIONS OF THE ATMOSPHERE
C                   URBAN, TROPOSPHERIC, STRATOSPHERIC
C *********************************************************************
C NCS     = 1..NCSGAS FOR GAS CHEMISTRY
C PRESS3  = MODEL VERTICAL LAYER CENTER PRESSURE (MB)
C PLOURB  = PRES (MB), BELOW WHICH URBAN, URBAN/TROP, OR ALL CHEMISTRY OCCURS
C PLOTROP = PRES (MB), BELOW WHICH TROP,  URBAN/TROP, OR ALL CHEMISTRY OCCURS
C         =            ABOVE WHICH STRAT              OR ALL CHEMISTRY OCCURS
C
             IF (NCS.EQ.NCSURBAN) THEN
                NTLOOPUSE          = NTLOOPNCS(NCS)
                DO JLOOP        = 1, NTLOOPUSE
                   JREORDER(JLOOP)    = NCSLOOP(JLOOP,NCS)
                ENDDO
             ELSEIF (NCS.EQ.NCSTROP) THEN
                NTLOOPUSE          = NTLOOPNCS(NCS)
                DO JLOOP        = 1, NTLOOPUSE
                   JREORDER(JLOOP)    = NCSLOOP(JLOOP,NCS)
                ENDDO
             ELSEIF (NCS.EQ.NCSSTRAT) THEN
                NTLOOPUSE          = NTLOOPNCS(NCS)
                DO JLOOP        = 1, NTLOOPUSE
                   JREORDER(JLOOP)    = NCSLOOP(JLOOP,NCS)
                ENDDO
             ENDIF
C
          ENDIF
C         ENDIF IGLOBCHEM.EQ.0
C
C *********************************************************************
C             DETERMINE ORIGINAL NUMBER OF GRID BLOCKS
C *********************************************************************
C NBLOCKUSE = ORIGINAL NUMBER OF GRID BLOCKS FOR PREDICTING STIFFNESS
C IUSESIZE  = # OF GRID CELLS IN EACH GRID BLOCK
C NBLOCKUSE = HERE, TOTAL NUMBER OF GRID CELLS FOR CHEMISTRY CALCULATIONS
C JLOWVAR   = LOWEST GRID CELL NUMBER - 1 IN EACH GRID BLOCK
C
          ! Comment out write statements for now (bmy, 4/1/03)
          !write(6,*) 'in physproc, iglobchem= ',iglobchem
          !write(6,*) 'val of ntloopuse= ',ntloopuse

          NBLOCKUSE          = 1 + NTLOOPUSE / (KULOOP    + 0.0001d0)
          IAVBLOK            = 1 + NTLOOPUSE / (NBLOCKUSE + 0.0001d0)
          IAVGSIZE           = MIN0(IAVBLOK,KULOOP)
C
          JLOOPLO            = 0
          IREMAIN            = NTLOOPUSE
C
          DO 200 KBLK        = 1, NBLOCKUSE
           IUSESIZE          = MIN(IAVGSIZE,MAX(IREMAIN,0))
           JLOWVAR(KBLK)     = JLOOPLO
           KTLPVAR(KBLK)     = IUSESIZE
           IREMAIN           = IREMAIN - IUSESIZE
           JLOOPLO           = JLOOPLO + IUSESIZE
 200      CONTINUE

          ! Added fix for small (1 to 3) KULOOP (10/5/07, phs)
          IF (IREMAIN /= 0) THEN
             DO WHILE ( IREMAIN /= 0 )
                NBLOCKUSE          = NBLOCKUSE + 1
                IUSESIZE           = MIN(IAVGSIZE,MAX(IREMAIN,0))
                JLOWVAR(NBLOCKUSE) = JLOOPLO
                KTLPVAR(NBLOCKUSE) = IUSESIZE
                IREMAIN            = IREMAIN - IUSESIZE
                JLOOPLO            = JLOOPLO + IUSESIZE
             END DO
          ENDIF

C
C *********************************************************************
C                  NUMBER OF GRID BLOCKS AFTER REORDERING 
C *********************************************************************
C
         ELSE 
          NBLOCKUSE          = NREBLOCK
         ENDIF
C        ENDIF ISREORD.EQ.LOREORD
C
C *********************************************************************
C                          SET LREORDER ARRAY
C *********************************************************************
C LREORDER = GIVES ORIGINAL GRID CELL FROM RE-ORDERED CELL
C

         DO 340 JLOOPN      = 1, NTLOOPUSE
 340      LREORDER(JLOOPN)  = JREORDER(JLOOPN)
C
C *********************************************************************
C                   START GRID BLOCK LOOP
C *********************************************************************
C
!--- Moved from chemdr.f (ccc, 12/9/09)
          IF ( LKPP) NTT = NTTLOOP

!$OMP PARALLEL DO
!$OMP+DEFAULT( SHARED )
!$OMP+PRIVATE( JLOOP,KLOOP,KBLK2,JNEW,JOLD)
!$OMP+SCHEDULE( DYNAMIC )

         DO 640 KBLK2       = 1, NBLOCKUSE
          KBLK              = KBLK2
          JLOOPLO           = JLOWVAR(KBLK)
          KTLOOP            = KTLPVAR(KBLK)
C

          IF (KTLOOP.EQ.0) GOTO 640

C *********************************************************************
C *  PLACE LARGE DOMAIN GAS ARRAY (# CM-3) INTO SMALLER BLOCK ARRAY   *
C *********************************************************************
C CINIT  = INITIAL CONC (MOLEC. CM-3), USED TO CALCULATE RATES IN CALCRATE
C CORIG  = INITIAL CONC (MOLEC. CM-3), USED TO RESTART SMVGEAR IF A FAILURE
C NTSPEC = NUMBER OF ACTIVE PLUS INACTIVE GASES.
C MAPPL  = MAPS ORIGINAL SPECIES NUMBERS TO SPECIES NUMBERS
C          RE-ORDERED FOR CHEMISTRY.
C
             DO 572 JOLD         = 1, NTSPEC(NCS)
                JNEW               = MAPPL(JOLD,NCS)
                DO 570 KLOOP       = 1, KTLOOP
                   JLOOP             = JREORDER(JLOOPLO+KLOOP)
                   CBLK( KLOOP,JOLD) = CSPEC(JLOOP,JOLD)
                   CORIG(KLOOP,JNEW) = CSPEC(JLOOP,JOLD)
 570            CONTINUE
 572         CONTINUE
C
C *********************************************************************
C *              CALCULATE REACTION RATE COEFFICIENTS                 *
C *********************************************************************
C

          CALL CALCRATE(SUNCOS)

!--- Previous to (ccc, 12/9/09)
!          !***************KPP_INTERFACE****************
!          IF ( LKPP ) THEN
!             DO KLOOP = 1, KTLOOP        
!                JLOOP         = JREORDER(JLOOPLO+KLOOP)
!                DO NK          = 1, NTRATES(NCS)
!                   R_KPP(JLOOP,NK) = RRATE_FOR_KPP(KLOOP,NK)
!                ENDDO
!             ENDDO
!          ENDIF
!          !********************************************

C *********************************************************************
C *                        SOLVE CHEMICAL ODES                        *
C *********************************************************************
C
!--- Move call to KPP here from chemdr.f to save memory space
!    (ccc, 12/9/09)
!    NSPEC(1) is the # of active species for urban chemistry.
!    (ccc, 01/20/10)
          IF ( LKPP) THEN
             
             CALL GCKPP_DRIVER(KTLOOP, JLOOPLO, RRATE_FOR_KPP, NSPEC(1))

          ELSE
             CALL SMVGEAR
C
C *********************************************************************
C * REPLACE BLOCK CONCENTRATIONS (# CM-3) INTO DOMAIN CONCENTRATIONS  *
C *********************************************************************
C ISREORD = 1: CALL CALCRATE TO FIND STIFFNESS OF EACH GRID-CELL     
C ISREORD = 2: SET CHEMISTRY RATES AND SOLVE EQUATIONS                
C GQSCHEM   = CHANGE IN (# OF MOLECULES) OVER THE ENTIRE GRID OF EACH 
C             SPECIES AS A RESULT OF CHEMISTRY.
C GRIDVH   = GRID CELL VOLUME (CM3) 
C CNEW     = # CM-3
C C        = # CM-3 
C
             IF (ISREORD.EQ.2) THEN
                DO 620 JNEW         = 1, ISCHANG(NCS)
                   JOLD               = INEWOLD(JNEW,NCS)
                   DO 620 KLOOP       = 1, KTLOOP
                      JLOOP             = JREORDER(JLOOPLO+KLOOP)
                      CSPEC(JLOOP,JOLD) = MAX(CNEW(KLOOP,JNEW),SMAL2)
 620            CONTINUE
             ENDIF
          ENDIF
C
          
 640      CONTINUE
!$OMP END PARALLEL DO
C        CONTINUE KBLK = 1, NBLOCKUSE
C
C *********************************************************************
C *           REORDER GRID-CELLS FROM LEAST TO MOST STIFF             *
C *********************************************************************
C AT SUNRISE/SET REORDER CELLS SO THOSE WITH SIMILAR SUNRISE GROUP TOGETHER
C OTHERWISE,  REORDER CELLS SO THOSE WITH SIMILAR STIFFNESS GROUP TOGETHER
C JREORDER  = GIVES ORIGINAL  GRID-CELL FROM RE-ORDERED GRID-CELL
C LREORDER  = GIVES ORIGINAL GRID CELL FROM RE-ORDERED CELL, EXCEPT, 
C             WHEN CELL IS A VIRTUAL BOUNDARY CELL, THEN LREORDER 
C             GIVES ORIGINAL EDGE CELL FROM RE-ORDERED V. B. CELL 
C JLOOPC    = IDENTIFIES AN EDGE CELL FOR EACH VIRTUAL BOUNDARY CELL; 
C             OTHERWISE, IDENTIFIES THE JLOOP CELL 
C

         !==============================================================
         ! New additions to reordering based on Loretta's implementation
         ! (bdf, 4/1/03)
         !==============================================================
         IF (ISREORD.EQ.1) THEN
            NSUNRISE = 0
            NSUNSET  = 0

            DO 660 JLOOP = 1, NTLOOPUSE
               JLOOPC    = LREORDER(JLOOP)
               IX        = IXSAVE(JLOOPC)
               IY        = IYSAVE(JLOOPC)
               IJWINDOW  = (IY-1)*IIPAR + IX

               IF( SUNCOS(IJWINDOW) .GT. -.25 .AND.
     &             SUNCOS(IJWINDOW) .LT. .25 ) THEN
                  ITWO(JLOOP)  = 1
                  NSUNRISE     = NSUNRISE + 1
                  CSUMA(JLOOP) = SUNCOS(IJWINDOW) - 
     &                           ABS( SUNCOSB(IJWINDOW) )
               ELSE
                  ITWO(JLOOP)  = 0
                  CSUMA(JLOOP) = ERRMX2(JLOOP)
               ENDIF
 660        CONTINUE

            NNORISE = NTLOOPUSE - NSUNRISE - NSUNSET

            DO 670 JLOOP = 1, NTLOOPUSE
               LREORDER(JLOOP) = JREORDER(JLOOP)
               CSUMC(   JLOOP) = CSUMA(   JLOOP)
 670        CONTINUE
C
C *********************************************************************
C    REORDER GRID-CELLS SO ALL CELLS WHERE SUNSET OCCURS ARE AT END
C         LREORDER AND CSUMC ARE USED HERE ONLY TO STORE VALUES
C        OF JREORDER AND CSUMA TEMPORARILY AND ARE USED ELSEWHERE
C                       FOR A DIFFERENT PURPOSE. 
C *********************************************************************
C
          JLLAST             = NTLOOPUSE 
          DO 700 JLOOP       = 1, NTLOOPUSE
           IF (ITWO(JLOOP).EQ.2) THEN
            JREORDER(JLLAST) = LREORDER(JLOOP) 
            CSUMA(   JLLAST) = CSUMC(   JLOOP) 
            JLLAST           = JLLAST - 1 
           ENDIF
 700      CONTINUE
C
C *********************************************************************
C    NOW REORDER GRID-CELLS SO ALL CELLS WHERE SUNRISE OCCURS ARE 
C           IMMEDIATELY BEFORE CELLS WHERE SUNSET OCCURS 
C *********************************************************************
C
          DO 705 JLOOP       = 1, NTLOOPUSE
           IF (ITWO(JLOOP).EQ.1) THEN
            JREORDER(JLLAST) = LREORDER(JLOOP) 
            CSUMA(   JLLAST) = CSUMC(   JLOOP) 
            JLLAST           = JLLAST - 1 
           ENDIF
 705      CONTINUE
C
C *********************************************************************
C FINALLY, PLACE ALL OTHER GRID CELLS BEFORE SUNRISE AND SUNSET CELLS.
C              JLLAST WILL EQUAL ZERO AFTER THIS LOOP 
C *********************************************************************
C
          DO 710 JLOOP       = 1, NTLOOPUSE
           IF (ITWO(JLOOP).EQ.0) THEN
            JREORDER(JLLAST) = LREORDER(JLOOP) 
            CSUMA(   JLLAST) = CSUMC(   JLOOP) 
            JLLAST           = JLLAST - 1 
           ENDIF
 710      CONTINUE 
C
C *********************************************************************
C REORDER GRID-CELLS IN THREE STEPS:
C   1) WHERE NO SUNRISE/SET, FROM LEAST TO MOST STIFF 
C      (SMALLER ERRMX2 (CSUMA) -->LESS STIFF) 
C      CSUMA = ERRMX2
C   2) WHERE SUNRISE OCCURS, FROM TIME OF SUNRISE 
C      CSUMA = TIME OF SUNRISE (IN SECONDS PAST MIDNIGHT)
C   3) WHERE SUNSET  OCCURS, FROM TIME OF SUNSET  
C      CSUMA = TIME OF SUNSET (IN SECONDS PAST MIDNIGHT)
C
C SORT USING HEAPSORT ROUTINE (NUMERICAL RECIPES), AN N(logb2)N PROCESS 
C THIS REORDERING SCHEME IS VERY FAST, ALTHOUGH COMPLICATED.
C ERRMX2 FROM SMVGEAR: DENOTES STIFFNESS (LARGER VALUE --> MORE STIFF).
C *********************************************************************
C
          DO 760 IT             = 1, 3 
           IF (IT.EQ.1) THEN
            IRADD               = 0.d0
            LVAL                = IRADD + NNORISE  * 0.5d0 + 1
            IRVAL               = IRADD + NNORISE
           ELSEIF (IT.EQ.2) THEN
            IRADD               = NNORISE 
            LVAL                = IRADD + NSUNRISE * 0.5d0 + 1
            IRVAL               = IRADD + NSUNRISE
           ELSEIF (IT.EQ.3) THEN
            IRADD               = NNORISE + NSUNRISE  
            LVAL                = IRADD + NSUNSET  * 0.5d0 + 1
            IRVAL               = IRADD + NSUNSET 
           ENDIF 
C
           IRADD1               = IRADD + 1
C
           IF (IRVAL.GT.IRADD1) THEN
C
 800        IF (LVAL.GT.IRADD1) THEN
             LVAL                = LVAL - 1
             VALLOW              = CSUMA(   LVAL)
             JREORD              = JREORDER(LVAL)        
            ELSE 
             VALLOW              = CSUMA(   IRVAL)
             JREORD              = JREORDER(IRVAL)        
             CSUMA(   IRVAL)     = CSUMA(   IRADD1)
             JREORDER(IRVAL)     = JREORDER(IRADD1) 
             IRVAL               = IRVAL - 1
             IF (IRVAL.EQ.IRADD1) THEN
              CSUMA(    IRADD1)  = VALLOW
              JREORDER( IRADD1)  = JREORD
              GOTO 760 
             ENDIF
            ENDIF
            IPAR                 = LVAL
            JPAR                 = LVAL + LVAL - IRADD 
C
 820        IF (JPAR.LE.IRVAL) THEN
             IF (JPAR.LT.IRVAL) THEN
              JPAR1              = JPAR + 1
              IF (CSUMA(JPAR).LT.CSUMA(JPAR1)) JPAR = JPAR1
             ENDIF
             IF (VALLOW.LT.CSUMA(JPAR)) THEN
              CSUMA(   IPAR)     = CSUMA(   JPAR)
              JREORDER(IPAR)     = JREORDER(JPAR)
              IPAR               = JPAR
              JPAR               = JPAR + JPAR - IRADD 
              GOTO 820 
             ENDIF
            ENDIF
C
            CSUMA(   IPAR)       = VALLOW
            JREORDER(IPAR)       = JREORD 
            GOTO 800  
C
           ENDIF
C          ENDIF IRVAL.GT.0
 760      CONTINUE 
C
C *********************************************************************
C  DETERMINE HOW MANY BLOCKS ARE NEEDED IN EACH REORDER GROUP (SUNRISE,
C                 SUNSET, STIFFNESS) AFTER REORDERING
C *********************************************************************
C NBLOCKROW = # BLOCKS OF EACH REORDER GROUP (STIFFNESS, SUNRISE, SUNSET)
C IUSESIZE  = # OF GRID CELLS IN EACH GRID BLOCK
C NCELLROW  = # OF GRID CELLS IN EACH REORDER GROUP
C NNORISE   = # OF STIFFNESS (NON-SUNRISE, NON-SUNSET) CELLS
C NSUNRISE  = # OF SUNRISE CELLS
C NSUNSET   = # OF SUNSET  CELLS
C NREBLOCK  = COUNTS NUMBER OF NEW BLOCKS
C

          NSUMBLOCK        = 0
          NREBLOCK         = 0
          JLOOPLO          = 0 
C
          !write(6,*) 'norise,sunrise,sunset=',nnorise,nsunrise,nsunset
          DO 770 IT        = 1, 3
           IF (IT.EQ.1) THEN
            NCELLROW       = NNORISE
            NBLOCKROW      = 1 + NCELLROW / (KULOOP    + 0.0001d0)
           ELSEIF (IT.EQ.2) THEN
            NCELLROW       = NSUNRISE
            !NBLOCKROW      = 1 + NCELLROW * 3./ (KULOOP  + 0.0001d0)
           NBLOCKROW      = 1 + NCELLROW / (KULOOP  + 0.0001d0)
           ELSEIF (IT.EQ.3) THEN
            NCELLROW       = NSUNSET
            !NBLOCKROW      = 1 + NCELLROW * 3./ (KULOOP  + 0.0001d0)
           NBLOCKROW      = 1 + NCELLROW / (KULOOP  + 0.0001d0)
           ENDIF
C
           NSUMBLOCK       = NSUMBLOCK + NBLOCKROW
C
           IF (NSUMBLOCK.GT.MXBLOCK) THEN
!            write(6,*) 'val of mxblock= ',mxblock
!            WRITE(6,*)'PHYSPROC: NSUMBLOCK>MXBLOCK. INCREASE MXBLOCK ',
!     1                 NSUMBLOCK, NNORISE, NSUNRISE, NSUNSET, KULOOP 
            STOP
           ENDIF
C
           IF (NCELLROW.EQ.0) THEN
            NBLOCKROW      = 0
           ELSE
            IAVBLOK            = 1 + NCELLROW / (NBLOCKROW + 0.0001d0)
            IAVGSIZE           = MIN(IAVBLOK,KULOOP)
            IREMAIN            = NCELLROW
C
            !write(6,*) 'it,nblockrow,iavesize= ',it,nblockrow,iavgsize
            DO 765 KBLK        = 1, NBLOCKROW
             NREBLOCK          = NREBLOCK + 1
             IUSESIZE          = MIN(IAVGSIZE,MAX(IREMAIN,0))
             JLOWVAR(NREBLOCK) = JLOOPLO
             KTLPVAR(NREBLOCK) = IUSESIZE
             IREMAIN           = IREMAIN - IUSESIZE
             JLOOPLO           = JLOOPLO + IUSESIZE
 765        CONTINUE
           ENDIF
 770      CONTINUE
C770      CONTINUE IT = 1, 3
C
        ENDIF
C       ENDIF ISREORD.EQ.1 
C
 855   CONTINUE
 860  CONTINUE
C     CONTINUE ISREORD = 1, 2
C     CONTINUE NCS     = ILNCS, IHNCS
C
C *********************************************************************
C * EITHER WRITE OUTPUT TO COMPARE.OUT IF ITESTGEAR=2 OR COMPARE      *
C * ACCURATE RESULTS FROM COMPARE.DAT TO MODEL RESULTS IF ITESTGEAR=1 * 
C *********************************************************************
C AVGERR   = ABSOLUTE-VALUE AVERAGE SPECIES ERROR OVER ALL NGCOUNT SPECIES
C AVGHI    = ABSOLUTE-VALUE AVERAGE SPECIES ERROR OVER ALL NGHI SPECIES
C CMODEL   = CONCENTRATION FROM MODEL RESULTS
C GEARCONC = CONCENTRATION FROM FILE compare.dat
C NGCOUNT  = # SPECIES WITH CONCENTRATION GREATER THAN CLO1  
C NGHI     = # SPECIES WITH CONCENTRATION GREATER THAN CLO2 
C NOCC     = # OF TIMES ERRORS ARE CALCULATED (ONCE EACH TIME-INTERVAL)
C RMSCUR   = ROOT-MEAN-SQUARE ERROR OVER ALL NGCOUNT SPECIES
C RMSCURH  = ROOT-MEAN-SQUARE ERROR OVER ALL NGHI SPECIES
C
C OTHER PARAMETERS DEFINED IN DEFINE.DAT
C
!phs!       IF (ITESTGEAR.GT.0) THEN
!phs!        NCS            = 1
!phs!        IF (IRCHEM.EQ.1) WRITE(IOUT,980)
!phs!        ICG            = ISCHANG(NCS)
!phs!        CLO1           = 1.0d-05 
!phs!        CLO2           = 1.0d+03    
!phs! C
!phs!        DO 970 JNEW    = 1, ICG
!phs!         JOLD          = INEWOLD(JNEW,NCS)
!phs!         CMODEL(JNEW)  = CSPEC(LLOOP,JOLD)
!phs!  970   CONTINUE
!phs! C
!phs!        IF (ITESTGEAR.EQ.2) THEN
!phs!         WRITE(KCPD,996) TIME,DELT,IRCHEM,(NAMENCS(INEWOLD(I,NCS),NCS),
!phs!      1                  CMODEL(I),I=1,ICG)
!phs!        ENDIF
!phs! C
!phs!        IF (ITESTGEAR.EQ.1) THEN
!phs!         SUMFRACS      = 0.d0
!phs!         SUMRMS        = 0.d0
!phs!         SUMHI         = 0.d0
!phs!         SUMRMSH       = 0.d0
!phs!         NGCOUNT       = 0
!phs!         NGHI          = 0
!phs! C       WRITE(IOUT,982)
!phs!         IF (IRCHEM.EQ.1)  WRITE(IOUT,988)
!phs! C
!phs!         DO 975 JNEW   = 1, ICG
!phs!          JOLD         = INEWOLD(JNEW,NCS)
!phs!          CMOD         = CMODEL(JNEW)
!phs!          CGOOD        = GEARCONC(JNEW,IRCHEM,NCS)
!phs!          IF (CGOOD.GT.CLO1.AND.CMOD.GT.CLO1.AND.CGOOD.GT.1.d-5*
!phs!      1       CPREV(JNEW)) THEN 
!phs!           FRACDIF     = (CMOD - CGOOD) / CGOOD
!phs!           FRACABS     = ABS(FRACDIF)
!phs!           SUMFRACS    = SUMFRACS + FRACABS 
!phs!           SUMRMS      = SUMRMS   + FRACABS * FRACABS
!phs!           NGCOUNT     = NGCOUNT + 1
!phs!           IF (CGOOD.GT.CLO2.AND.CMOD.GT.CLO2) THEN
!phs!            SUMHI      = SUMHI    + FRACABS 
!phs!            SUMRMSH    = SUMRMSH  + FRACABS * FRACABS
!phs!            NGHI       = NGHI     + 1
!phs!            IAVG       = 2
!phs!           ELSE
!phs!            IAVG       = 1
!phs!           ENDIF
!phs!          ELSE
!phs!           FRACDIF     = 0.d0
!phs!           IAVG        = 0
!phs!          ENDIF
!phs!          CPREV(JNEW)  = CGOOD
!phs! C        WRITE(IOUT,984) NAMENCS(JOLD,NCS),CGOOD,CMOD,FRACDIF*100.,IAVG
!phs!  975    CONTINUE
!phs! C
!phs!         IF (NGCOUNT.GT.0) THEN
!phs!          AVGERR     = 100.d0 * SUMFRACS     / NGCOUNT  
!phs!          RMSCUR     = 100.d0 * SQRT(SUMRMS  / NGCOUNT)
!phs!         ELSE
!phs!          AVGERR     = 0.d0
!phs!          RMSCUR     = 0.d0
!phs!         ENDIF
!phs! C
!phs!         IF (NGHI.GT.0) THEN
!phs!          AVGHI       = 100.d0 * SUMHI        / NGHI  
!phs!          RMSCURH     = 100.d0 * SQRT(SUMRMSH / NGHI)
!phs!         ELSE
!phs!          AVGHI       = 0.d0
!phs!          RMSCURH     = 0.d0
!phs!         ENDIF
!phs! C
!phs!         SUMAVGE     = SUMAVGE + AVGERR
!phs!         SUMAVHI     = SUMAVHI + AVGHI
!phs!         SUMRMSE     = SUMRMSE + RMSCUR
!phs!         SUMRMHI     = SUMRMHI + RMSCURH
!phs!         NOCC        = NOCC    + 1
!phs! C
!phs!         FSTEPT   = FLOAT(NPDERIV)
!phs!         FITS     = FLOAT(NSUBFUN)
!phs! C
!phs!         TOTSTEP  = TOTSTEP + FSTEPT 
!phs!         TOTIT    = TOTIT   + FITS
!phs!         TELAPS   = TELAPS  + XELAPS 
!phs!         WRITE(IOUT,992) IRCHEM,TIME,FSTEPT,FITS,FITS/FSTEPT,
!phs!      1                  NGCOUNT,NGHI,AVGERR,AVGHI,RMSCUR,RMSCURH
!phs!        ENDIF
!phs!       ENDIF
!phs! C
C *********************************************************************
C *                            FORMATS                                * 
C *********************************************************************

 980  FORMAT(20X,'RESULTS FROM SUBROUTINE CALCRATE.F')
C982  FORMAT(4X,'SPECIES',5X,'GEARCONC      MODEL      % ERROR IFAVG')
C984  FORMAT(A14,2(1X,1PE11.4),2X,0PF8.2,'%',3X,I1)
 988  FORMAT(/8X,'STATISTICS FROM COMPARISON OF SMVGEAR RESULTS TO ', 
     1       'compare.dat'//
     1       'IRCHEM,ELAPST   PDERIV  SUBFUN  SF/PD  #AVG #HI ',
     1       'AVGERR  AVGI    RMS    RMSHI')
 992  FORMAT(I3,1X,3(F8.0,1X),F6.2,1X,I3,1X,I3,4(1X,0PF7.2)) 
 994  FORMAT('***********************************OVERALL************', 
     1       '***********************')
 996  FORMAT('CONC (# CM-3 OR M L-1) AT TIME=',1PE10.2,' SECONDS. ',  
     1       'DELT=',E10.2,' . RUN =',I3/3(A13,'=',E11.4,1X))
 998  FORMAT('END')
1000  FORMAT('END            9.9999E+99')
1002  FORMAT(/3X,'FINAL STATISTICS FROM SMVGEAR. GRID-BLOCK     = ',I4/
     1        '# CALLS TO SUBROUTINE SUBFUN                     = ',I8/
     2        '# CALLS TO SUBROUTINE PDERIV                     = ',I8/ 
     3        '# SUCCESSFUL TIME-STEPS                          = ',I8/  
     4        '# CORRECTOR ITERATION FAILURES (IFAIL)           = ',I8/  
     5        '# CORRECTOR FAILURES AFTER PDERIV CALLED (NFAIL) = ',I8/  
     6        '# ACCUMULATED ERROR TEST FAILURES (LFAIL)        = ',I8)   
C
C *********************************************************************
C ********************* END OF SUBROUTINE PHYSPROC.F ******************
C *********************************************************************
C
      RETURN
      END SUBROUTINE PHYSPROC
