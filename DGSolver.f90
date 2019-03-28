! f2py -c --f90flags='-O3 -ffast-math -funroll-loops' -m dg_solver DGSolver.f90

module types
  ! integer, parameter:: dp=kind(0.d0)
  integer, parameter:: dp=8
  ! integer, parameter:: dp=kind(0.0)

end module types

module mesh
    use types
    implicit none

    integer:: nElem, nInEdge, nBCEdge

    ! these arrays are set on the python level

    real(dp), allocatable,  dimension(:,:):: inNormal
        !  2, nInEdge
        ! the normal for each interior normals

    real(dp), allocatable, dimension(:,:):: bcNormal
        !  2, nBCEdge
        ! the normal for each boundary normals

    real(dp), allocatable, dimension(:):: inLength
         ! nInEdge
         ! the length of each interior face

    real(dp), allocatable, dimension(:):: bcLength
        ! nBCEdge
        ! the length of each boundary face

    real(dp), allocatable, dimension(:):: area
        ! nElem
        ! the area of each element

    real(dp), allocatable, dimension(:,:,:):: elem2dX
        !  3, nElem
        ! disctance to cell center for  each element face

    integer, allocatable, dimension(:,:):: inEdge2Elem
         ! 4, nInEdge
        ! mapping from interior faces to  elements

    integer, allocatable, dimension(:,:):: bcEdge2Elem
         !  3, nBCEdge
        ! mapping from boundary faces to  elements




    ! BC integers used to compare with the BC value in bcElem2Node
    integer, allocatable, dimension(:):: wall, inlet, outlet

end module mesh


module constants
  use types

  implicit none
  real(dp), parameter:: gam=1.4_dp
  ! real(dp), parameter:: eps=0.1_dp
  real(dp), parameter:: R_gasconst=1.0_dp
  real(dp):: tempTot_inf, pTot_inf, p_inf, alpha
  real(dp), dimension(4):: Ub
  real(dp), parameter::gm1 = 1.4_dp - 1.0_dp

  integer:: mode=0
  integer:: recon_bc_flux=1
  integer:: recon_p=1

end module  constants

module fluxes
    use types
    implicit none

    contains

    subroutine roeFlux(UL, UR, normal, flux, S)
      ! Inputs: Ul, Ur, normal
      ! Output: flux, s

      use constants
      implicit none
      real(dp), dimension(2), intent(in) :: normal
      real(dp), dimension(4), intent(in):: UL, UR
      real(dp), dimension(4), intent(out)::  flux


      real(dp), intent(out):: S

      real(dp):: s1, s2, G1, G2, C1, C2
      real(dp):: dr, drE
      real(dp), dimension(2):: dru
      real(dp), dimension(3):: L


      real(dp), dimension(2) :: P, H
      real(dp), dimension(4) :: Fx, Fy
      real(dp), dimension(4,2) :: U

      ! roe averaged variables
      real(dp), dimension(2):: u_vec_roe
      real(dp)::  H_roe, u_roe, c_roe


      real(dp):: eps
      integer:: idx



      ! combine the two state vectors into one, becuase thats how the code was orignal written (with on U vector)
      U(:,1) = UL
      U(:,2) = UR

      flux = 0.0_dp

      do idx = 1,2
         P(idx) = (gm1)*(U(4,idx) - 0.5_dp*(norm2(U(2:3,idx))**2)/U(1,idx))
         if (P(idx) <= 0.0) write(*,*) "P", P
         H(idx) = (U(4,idx)+P(idx))/U(1,idx)

         Fx = (/ U(2,idx),&
         (U(2,idx)*U(2,idx)/U(1,idx) + P(idx)),&
         U(3,idx)*U(2,idx)/U(1,idx),&
         U(2,idx)*H(idx)/)

         Fy = (/ U(3,idx),&
         U(3,idx)*U(2,idx)/U(1,idx),&
         (U(3,idx)*U(3,idx)/U(1,idx) + P(idx)),&
         U(3,idx)*H(idx)/)

         flux = flux + 0.5_dp*(Fx*normal(1) + Fy*normal(2))

      end do


      ! get roe averages variables
      u_vec_roe(1) = getRoeAvg(U(2,:)/U(1,:), U(1,:))
      u_vec_roe(2) = getRoeAvg(U(3,:)/U(1,:), U(1,:))

      H_roe = getRoeAvg(H, U(1,:))
      u_roe = dot_product(u_vec_roe, normal)


      c_roe = sqrt((gam-1)*(H_roe - 0.5_dp*norm2(u_vec_roe)**2))

      L(1) = abs(u_roe + c_roe)
      L(2) = abs(u_roe - c_roe)
      L(3) = abs(u_roe)

      eps = c_roe * 0.1_dp
      do idx = 1,3
         if (abs(L(idx)) < eps ) then
           L(idx) = (eps**2 + L(idx)**2)/(2*eps)
          end if
      end do

      s1 = 0.5_dp*(L(1) + L(2))
      s2 = 0.5_dp*(L(1) - L(2))

      dr =  U(1,2)-U(1,1)
      dru = U(2:3,2)-U(2:3,1)
      drE = U(4,2) - U(4,1)

      G1 = (gm1)*(0.5_dp*norm2(u_vec_roe)**2 *dr - dot_product(u_vec_roe, dru) + drE)
      G2 = -u_roe*dr + dot_product(dru, normal)

      C1 = (G1/c_roe*(s1 - L(3)) + G2 * s2)/c_roe
      C2 = G1/c_roe * s2 + (s1 - L(3))*G2

      flux = flux - 0.5_dp * (/ L(3)*dr + C1, L(3)*dru + C1*u_vec_roe + C2 * normal, L(3)*drE + C1*H_roe + C2*u_roe /)

      S = maxval(L)
      ! write(*,*) flux

    end subroutine


    subroutine wallFlux(U_in, normal, flux, smag)
        ! This routine calculates the flux for the Euler equations at an inviscid wall
        use constants, only: gam, gm1

        implicit none

        ! Arguments declarations
        real(dp), dimension(4), intent(in) :: U_in
        real(dp), dimension(2), intent(in) :: normal
        real(dp), dimension(4), intent(out) :: flux
        real(dp), intent(out) :: smag
        real(dp) :: pb, rL , pL
        real(dp):: unL, qL, utL

        rL = U_in(1)
        pL = (gm1)*(U_in(4) - 0.5_dp*U_in(1)*norm2(U_in(2:3)/U_in(1))**2)

        unL = dot_product(U_in(2:3), normal)/rL
        qL  = sqrt(U_in(2)**2 + U_in(3)**2)/rL;
        utL = sqrt(qL**2 - unL**2);

        pb = (gam-1)*(U_in(4) - 0.5_dp*rL*utL**2)
        if ((pb<=0) .or. (rL<=0)) write(*,*) 'Non-physical state! P ', pb, 'rho ', rL

        smag = abs(unL) + sqrt(gam*pL/rL)

        flux = (/0.0_dp , pb*normal(1), pb*normal(2), 0.0_dp /)


    end subroutine  WallFlux


    subroutine inflowFlux(U_in, n, flux, smag)
      ! PURPOSE: This routine calculates the inflow flux given stagnation
      ! quantities, flow angle, the interior state, the outward normal,
      ! and gamma.
      !
      ! INPUTS:
      ! U_in : domain-interior state
      ! n : normal pointing out of the domain
      ! gamma : ratio of specific heats
      !
      ! OUTPUTS:
      ! flux : the flux dotted with the normal (i.e. out of the cell)
      ! smag : the maximum propagation speed of disturbances

      use constants, only: gam, R_gasconst, gm1, tempTot_inf, pTot_inf, alpha
      implicit none

      ! Arguments declarations
      real(dp), dimension(4), intent(in) :: U_in
      real(dp), dimension(2), intent(in) :: n
      real(dp), dimension(4), intent(out) :: flux !m2f: check dim(:)!m
      real(dp), intent(out) :: smag

      ! Variable declarations
      real(dp):: a, b, c
      real(dp):: cB, cI, disc
      real(dp):: dn

      real(dp):: Jp
      real(dp):: MB, MB1, MB2, Mfac
      real(dp):: pB, pI
      real(dp):: rB, rEB, rI
      real(dp):: RTB, RTt

      real(dp), dimension(4):: UB
      real(dp):: unB, unI


      ! ! interior density and velocity
      rI = U_in(1)

      ! ! interior normal velocity
      unI = dot_product(U_in(2:3), n)/rI

      ! ! interior pressure
      pI = gm1*(U_in(4) - 0.5_dp*norm2(U_in(2:3))**2/rI)
      if ((pI<=0) .or. (rI<=0)) write(*,*) 'Non-physical state)', pI, rI


      ! exterior total temperature times the gas constant
      RTt = tempTot_inf*R_gasconst

      ! interior speed of sound
      cI = sqrt(gam*pI/rI)

      ! interior Riemann invariant
      Jp = unI + 2.0_dp*cI/gm1

      ! solve for MB = exterior Mach number
      dn = n(1)*cos(alpha) + n(2)*sin(alpha)
      a = gam*RTt*dn**2 - 0.5_dp*gm1*Jp*Jp ! MB**2 coeff
      b = 4.0_dp*gam*RTt*dn/gm1 ! MB**1 coeff
      c = 4.0_dp*gam*RTt/(gm1**2) - Jp*Jp ! MB**0 coeff
      disc = b*b-4.0_dp*a*c ! discriminant
      if (disc <= 0) write(*,*) 'No solution for MB in inflow flux calc.'

      MB1 = 0.5_dp*(-b-sqrt(disc))/a
      MB2 = 0.5_dp*(-b+sqrt(disc))/a

      if ((MB1 < 0.) .and. (MB2 < 0.)) then
        write(*,*) '*Error* Negative Mach number at inflow'
        write(*,*) 'MB1', MB1, 'MB2', MB2
        write(*,*) 'gam', gam, 'RTt', RTt
        write(*,*) 'a', a, 'b', b, 'c', c

      else if (MB1 < 0.) then ! MB2 is non-negative
        MB = MB2
      else if (MB2 < 0.) then ! MB1 is non-negative
        MB = MB1
      else ! both non-negative
        MB = min(MB1, MB2)
      end if


      ! compute exterior state
      Mfac = 1. + 0.5_dp*gm1*MB*MB
      RTB = RTt/Mfac ! exterior res * temperature
      pB = pTot_inf*Mfac**(-gam/gm1) ! exterior pressure
      rB = pB/(RTB) ! exterior density
      cB = sqrt(gam*pB/rB) ! exterior speed of sound


      rEB = pB/gm1 + 0.5_dp*rB*(cB*MB)**2 ! exterior energy
      unB = cB*MB*cos(alpha)*n(1) + cB*MB*sin(alpha)*n(2)
      UB = [ rB,rB*cB*MB*cos(alpha),rB*cB*MB*sin(alpha), rEB ] ! exterior state vector

      ! exterior flux
      flux = (/rB*unB, UB(2)*unB + pB*n(1), UB(3)*unB + pB*n(2), (UB(4) + pB)*unB/)

      ! max wave speed
      smag = abs(unB) + cB



    end subroutine  InflowFlux

    subroutine outflowFlux(U_in, normal, flux, smag)
      ! PURPOSE: This routine calculates the outflow flux
      !
      ! INPUTS:
      ! U: conservative state vector
      ! normal: normal pointing from the left cell to the right cell
      ! gamma: Ratio of specific heats
      !
      ! OUTPUTS:
      ! flux : flux dotted with the normal
      ! smag: the maximum propagation speed of disturbances
      !

      use constants, only: p_inf, gam, gm1
      ! Arguments declarations
      real(dp), dimension(4), intent(in) :: U_in
      real(dp), dimension(2), intent(in) :: normal
      real(dp), dimension(4), intent(out) :: flux
      real(dp), intent(out) :: smag

      ! Variable declarations
      real(dp) :: p_in, r_in, s_in

      real(dp):: c_out, c_in, velnorm_out, J
      real(dp) :: r_out


      real(dp), dimension(4):: flux_x, flux_y
      real(dp), dimension(2):: vel_in, vel_out
      real(dp) :: H_out, rE_out

      !interior density and velocity
      r_in = U_in(1)
      vel_in = U_in(2:3)/r_in

      ! ! interior pressure
      p_in = (gm1)*(U_in(4) - 0.5_dp*r_in*norm2(vel_in)**2)
      s_in = p_in/r_in**gam

      if ((p_in<=0) .or. (r_in<=0)) write(*,*) 'Non-physical state)', p_in, r_in

      ! exterior total temperature times the gas constant
      r_out = (p_inf/s_in)**(1/gam)

      ! speed of sound
      c_out = sqrt(gam*p_inf/r_out)
      c_in = sqrt(gam*p_in/r_in)

      ! interior Riemann invariant
      J = dot_product(vel_in, normal) + 2*c_in/(gm1)

      velnorm_out = J - 2*c_out/(gm1)

      vel_out = vel_in - dot_product(vel_in, normal)*normal + velnorm_out * normal


      rE_out = p_inf/(gm1) + 0.5_dp*r_out*norm2(vel_out)**2
      H_out = (rE_out+p_inf)/r_out

      flux_x = (/ r_out*vel_out(1), r_out*vel_out(1)**2 + p_inf, r_out*vel_out(1)*vel_out(2), r_out*vel_out(1)*H_out/)
      flux_y = (/ r_out*vel_out(2), r_out*vel_out(1)*vel_out(2)  ,  r_out*vel_out(2)**2 + p_inf, r_out*vel_out(2)*H_out/)

      flux = flux_x*normal(1) + flux_y*normal(2)

      smag = abs(velnorm_out) + c_out


    end subroutine  !OutFlowFlux


   subroutine analyticFlux(U, flux)
      use constants

      real(dp), dimension(4), intent(in) :: U
      real(dp), dimension(2,4), intent(out) :: flux


      real(dp) :: P, H
      real(dp), dimension(4) :: Fx, Fy


      P = (gm1)*(U(4) - 0.5_dp*(norm2(U(2:3))**2)/U(1))
      if (P <= 0.0) write(*,*) "P negative: analytical flux", P, U
      H = (U(4)+P)/U(1)

      Fx = (/ U(2),&
              (U(2)*U(2)/U(1) + P),&
               U(3)*U(2)/U(1),&
               U(2)*H/)
      Fy = (/ U(3),&
              U(3)*U(2)/U(1),&
              U(3)*U(3)/U(1) + P,&
              U(3)*H/)

      flux(1, :) = Fx
      flux(2, :) = Fy

   end ! analyticFlux

  !  function getP(state) result(P)

  !     real(dp), dimension(4):: state
  !     real(dp) :: P
  !     P = (gam - 1)*(state(4) - 0.5*state(1)*norm2(state(2:3))**2)
  !  end function

    function getRoeAvg(V, Rho) result(avg)
      real(dp), dimension(2):: Rho
      real(dp), dimension(:):: V
      real(dp):: avg

      avg = (V(1)*sqrt(Rho(1)) + V(2)*sqrt(Rho(2)))/(sqrt(Rho(1))+sqrt(Rho(2)))

    end function

end module fluxes


! module residuals
!       use types
!       use constants, only: mode
!       implicit none

!     contains
!     subroutine getResiduals(U, res, S)
!       ! calculates the residuals for the new states
!       use constants, only: tempTot_inf, pTot_inf ,p_inf, alpha, Ub
!       use mesh, only: wall, inlet, outlet,  nInEdge, nBCEdge, inLength, inNormal, inEdge2Elem, bcLength, bcNormal, bcEdge2Elem
!       use fluxes, only: roeFlux, wallFlux, inflowFlux, outflowFlux

!       real(dp), dimension(:, :), intent(in):: U

!       real(dp), dimension(:, :), intent(out):: res
!       real(dp), dimension(:), intent(out):: S
!       integer:: idx_edge, idx_left, idx_right
!       real(dp), dimension(4):: flux
!       real(dp), dimension(4, 2):: U_face
!       real(dp):: sface


!       res = 0.0_dp
!       S = 0.0_dp

!       do idx_edge = 1, nInEdge
!          ! get the elements connected to the edge
!          idx_left = inEdge2Elem(1,idx_edge)
!          idx_right = inEdge2Elem(3,idx_edge)

!          U_face(:,1) = U(:, idx_left)
!          U_face(:,2) = U(:, idx_right)

!          ! get the states
!          call roeflux(U_face, inNormal(:, idx_edge), flux, sface)

!          ! add residuals to running total
!          res(:, idx_left) = res(:, idx_left) + flux*inLength(idx_edge)
!          res(:, idx_right) = res(:, idx_right) - flux*inLength(idx_edge)
!          S(idx_left) = S(idx_left) + sface*inLength(idx_edge)
!          S(idx_right) = S(idx_right) + sface*inLength(idx_edge)
!       end do



!     ! BCs
!     do idx_edge = 1,nBCEdge
!       idx_left = bcEdge2Elem(1,idx_edge)
!       ! write(*,*) idx_left

!       if (mode==0) then
!         ! write(*,*) idx_left

!         if (any(bcEdge2Elem(3,idx_edge)== wall)) then
!           ! write(*,*) 'wall'
!           call wallFlux( U(:, idx_left), bcNormal(:, idx_edge), flux, sface)

!         else if (any(bcEdge2Elem(3,idx_edge)== inlet)) then
!           ! write(*,*) 'inlet'

!           call inflowFlux(temptot_inf, ptot_inf, alpha, U(:, idx_left), bcNormal(:, idx_edge), flux, sface)

!         else if (any(bcEdge2Elem(3,idx_edge)== outlet)) then
!           ! write(*,*) 'outlet', p_inf

!           call outflowFlux(p_inf, U(:, idx_left), bcNormal(:, idx_edge), flux, sface)

!         end if

!       else
!         ! write(*,*) 'Freestream'

!         ! freesteam bcs everywhere (flowthough test)
!         U_face(:,1) = U(:, idx_left)
!         U_face(:,2) = Ub
!         call roeFlux(U_face, bcNormal(:, idx_edge), flux, sface)

!       end if

!       res(:, idx_left) = res(:, idx_left) + flux*bcLength(idx_edge)
!       S(idx_left) = S(idx_left) + sface*bcLength(idx_edge)

!     end do



!    end subroutine !getResiduals

!   subroutine getGradU(U, dU_dX)

!     use mesh, only:   nInEdge, nBCEdge, inLength, inNormal, inEdge2Elem, bcLength, bcNormal, bcEdge2Elem, area


!     real(dp), dimension(:, :), intent(in):: U
!     real(dp), dimension(:, :, :), intent(out):: dU_dX

!     real(dp), dimension(4):: U_bar


!     integer:: idx_edge, idx_left, idx_right, idx_xy, idx_elem, i


!     dU_dX = 0.0_dp


!     ! write(*,*) ''
!     ! write(*,*) 'U '
!     ! do, i=1,nElem
!     !    write(*,*) U(:,i)
!     ! enddo

!     do idx_edge = 1, nInEdge
!       ! get the elements connected to the edge
!       idx_left = inEdge2Elem(1,idx_edge)
!       idx_right = inEdge2Elem(3,idx_edge)

!       U_bar = (U(:, idx_left) + U(:, idx_right))/2

!       ! w
!       do idx_xy = 1,2

!         ! WRITE(*,*) dU_dX(idx_xy,:,idx_left)
!         ! WRITE(*,*) dU_dX(idx_xy,:,idx_left) + U_bar*inLength(idx_edge)*inNormal(idx_xy, idx_edge)
!         dU_dX(idx_xy,:,idx_left) = dU_dX(idx_xy,:,idx_left) + U_bar*inLength(idx_edge)*inNormal(idx_xy, idx_edge)/area(idx_left)
!         dU_dX(idx_xy,:,idx_right) = dU_dX(idx_xy,:,idx_right) - U_bar*inLength(idx_edge)*inNormal(idx_xy, idx_edge)/area(idx_right)
!       end do
!     end do

!     ! loop over bc faces

!     do idx_edge = 1, nBCEdge
!       ! get the elements connected to the edge
!       idx_elem =  bcEdge2Elem(1,idx_edge)
!       ! idx_right = inEdge2Elem(3,idx_edge)

!       U_bar = U(:, idx_elem)

!       do idx_xy = 1,2
!         dU_dX(idx_xy,:,idx_elem) = dU_dX(idx_xy,:,idx_elem) + U_bar*bcLength(idx_edge)*bcNormal(idx_xy, idx_edge)/area(idx_elem)
!       end do
!     end do


!     ! do idx_elem = 1,nElem
!     !   dU_dX(:, :, idx_elem) = dU_dX(:, :, idx_elem)/area(idx_elem)
!     !   ! write(*,*) 'dU_dX(:, :, idx_elem)', dU_dX(:, :, idx_elem), area(idx_elem)
!     ! end do



!     ! write(*,*) ''
!     ! write(*,*) 'U gradu'
!     ! do, i=1,nElem
!     !    write(*,*) dU_dX(:,:,i)
!     ! enddo


!   end subroutine ! getGradU


!   subroutine getResiduals_2ndOrder(U, dU_dX, res, S)
!     ! calculates the residuals for the new states
!     use mesh, only: wall, inlet, outlet, nInEdge, nBCEdge, inLength, inNormal, inEdge2Elem, &
!     bcLength, bcNormal, bcEdge2Elem, elem2dX
!     use fluxes
!     use constants, only: tempTot_inf, pTot_inf ,p_inf, alpha, Ub, recon_bc_flux

!     implicit none
!     real(dp), dimension(:, :), intent(in):: U
!     real(dp), dimension(:, :, :), intent(inout):: dU_dX

!     real(dp), dimension(:, :), intent(out):: res
!     real(dp), dimension(:), intent(out):: S

!     integer:: idx_state, idx_edge, idx_left, idx_right
!     real(dp), dimension(4):: flux, U_edge, dU_left, dU_right
!     real(dp), dimension(4, 2):: U_face
!     real(dp), dimension(2):: dX_right, dX_left
!     real(dp):: sface


!     res = 0.0_dp
!     S = 0.0_dp


!     call getGradU(U, dU_dX)


!     do idx_edge = 1, nInEdge
!        ! get the elements connected to the edge
!        idx_left = inEdge2Elem(1,idx_edge)
!        idx_right = inEdge2Elem(3,idx_edge)

!       !  write(*,*) 'idx_left', idx_left, 'idx_right', idx_right

!        dX_left = elem2dX(:,inEdge2Elem(2,idx_edge), idx_left)
!        dX_right  = elem2dX(:,inEdge2Elem(4,idx_edge), idx_right)

!        do idx_state = 1,4
!         dU_left(idx_state) = dot_product(dX_left, dU_dX(:, idx_state ,idx_left) )
!         dU_right(idx_state) = dot_product(dX_right, dU_dX(:, idx_state ,idx_right) )
!        end do


!        U_face(:,1) = U(:, idx_left) + dU_left
!        U_face(:,2) = U(:, idx_right) + dU_right

!       !  write(*,*) 'UL', U_face(:,1), dU_left, dX_left
!       !  write(*,*) 'UR', U_face(:,2), dU_right, dX_right
!        ! get the states
!        call roeFlux(U_face, inNormal(:, idx_edge), flux, sface)
!       !  write(*,*) 'flux', flux

!        ! add residuals to running total

!        res(:, idx_left) = res(:, idx_left) + flux*inLength(idx_edge)
!        res(:, idx_right) = res(:, idx_right) - flux*inLength(idx_edge)

!        S(idx_left) = S(idx_left) + sface*inLength(idx_edge)
!        S(idx_right) = S(idx_right) + sface*inLength(idx_edge)

!     end do


!     ! Free stream BCs
!     do idx_edge = 1,nBCEdge
!       idx_left = bcEdge2Elem(1,idx_edge)

!       if (mode==0) then

!         U_edge = U(:, idx_left)
!         if (recon_bc_flux==1) then
!           dX_left = elem2dX(:,bcEdge2Elem(2,idx_edge), idx_left)

!           do idx_state = 1,4
!             dU_left(idx_state) = dot_product(dX_left, dU_dX(:, idx_state ,idx_left) )
!           end do
!           U_edge = U_edge + dU_left
!           ! write(*,*) dU_left
!         end if

!         if (any(bcEdge2Elem(3,idx_edge)== wall)) then
!           call WallFlux( U_edge, bcNormal(:, idx_edge), flux, sface)

!         else if (any(bcEdge2Elem(3,idx_edge)== inlet)) then
!           call InflowFlux(temptot_inf, ptot_inf, alpha, U_edge, bcNormal(:, idx_edge), flux, sface)

!         else if (any(bcEdge2Elem(3,idx_edge)== outlet)) then
!           call OutflowFlux(p_inf, U_edge, bcNormal(:, idx_edge), flux, sface)

!         end if

!       else
!         ! freesteam

!         U_face(:,1) = U(:, idx_left)
!         U_face(:,2) = Ub
!         call roeFlux(U_face, bcNormal(:, idx_edge), flux, sface)

!       end if

!       res(:, idx_left) = res(:, idx_left) + flux*bcLength(idx_edge)
!       S(idx_left) = S(idx_left) + sface*bcLength(idx_edge)

!     end do




!     ! write(*,*) ''
!     ! write(*,*) 'res'
!     ! do, i=1,nElem
!     !    write(*,*) res(:,i)
!     ! enddo


!   end subroutine !getResiduals



! end module residuals



! module FVSolver
!   use types
!   use constants, only: mode
!   use mesh, only: nElem
!   implicit none
!   ! integer:: nElem, nInEdge, nBCEdge

!   real(dp), allocatable,  dimension(:,:):: U
!       !  4, nelem
!       ! state in each cell
!   real(dp), allocatable,  dimension(:, :):: res
!       !  4, nelem
!       ! the residual in each cell
!   ! real(dp), allocatable, dimension(:):: S
!       ! nelem
!       ! maximum wave speed in each cell
!   real(dp), allocatable,  dimension(:,:,:):: dU_dX

!   real(dp):: CFL=1.0

!   real(dp), dimension(4):: Ub
!   integer, parameter:: iprint=200

! contains

!   subroutine solve_1storder(maxiter, tol, res_max, res_2)
!     ! after initalizing use explicit euler for time maching

!     use residuals, only: getResiduals
!     integer, intent(in):: maxiter
!     real(dp), intent(in):: tol
!     real(dp), dimension(maxiter), intent(out):: res_max, res_2
!     real(dp), allocatable,  dimension(:):: S

!     ! real(dp), intent(out), dimension(4,4):: u_sol
!     integer:: idx, iter


!     write(*,*) 'using first order solver'
!     ! allocate(u_sol(4,nElem))
!     ! allocate(S(nElem), res(4,nElem))
!     allocate(S(nElem))

!     do iter = 1, maxiter

!       call getResiduals(U, res,S)

!       res_max(iter) = maxval(abs(res))
!       res_2(iter) = norm2(res)

!       if (mod(iter, iprint) == 0) write(*,*) iter, res_max(iter)
!       if (res_max(iter) <= tol .and. mode==0) exit


!       ! write(*,*) ''
!       ! write(*,*) 'mode', mode
!       do idx = 1, nElem
!         ! write(*,*) U(:,idx)
!         U(:,idx) = U(:,idx) - 2*CFL/S(idx) *res(:,idx)
!       end do


!     end do
!     ! write(*,*) 'iter', iter




!     deallocate(S)
!   end subroutine ! solve_1storder

!   subroutine solve_2ndOrder(maxiter, tol, res_max, res_2)
!       ! after initalizing use rk2 for time maching

!       use residuals,  only: getResiduals_2ndOrder, getGradU

!       integer, intent(in):: maxiter
!       real(dp), intent(in):: tol
!       real(dp), dimension(maxiter), intent(out):: res_max, res_2

!       integer:: idx, iter

!       real(dp), allocatable, dimension(:,:):: U_FE, res, res_FE
!       real(dp), allocatable,  dimension(:):: S, dt_dA


!       IF( ALLOCATED(dU_dX) ) DEALLOCATE( dU_dX )
!       allocate(U_FE(4,nElem), S(nElem), dt_dA(nElem), res(4,nElem), res_FE(4,nElem), dU_dX(2,4,nElem))


!       write(*,*) 'using second order solver'
!       do iter = 1, maxiter


!         ! ! rk2 second stage

!         call getResiduals_2ndOrder(U, dU_dX, res, S)

!         res_max(iter) = maxval(abs(res))
!         res_2(iter) = norm2(res)

!         if (mod(iter, iprint) == 0) write(*,*) iter, res_max(iter)
!         if (res_max(iter) <= tol .and. mode==0) exit

!         ! apply explict euler update
!         do idx = 1, nElem
!             dt_dA(idx) = 2.0_dp*CFL/S(idx)
!             U_FE(:,idx) = U(:,idx) - dt_dA(idx) *res(:,idx)
!         end do


!         call getResiduals_2ndOrder(U_FE, dU_dX, res_FE, S)



!         ! rk2 second stage
!         do idx = 1, nElem
!             U(:,idx) = 0.5_dp*(U(:,idx) + U_FE(:,idx) -  dt_dA(idx)*(res_FE(:,idx)))
!         end do


!       end do


!       deallocate(U_FE, S, dt_dA, res, res_FE)
!     end subroutine !solver_2ndorder






! end module FVSolver

! module postProcess
!   use types

!   implicit none
!   real(dp), allocatable, dimension(:) :: p, mach, entropy

!   contains

!   subroutine getFeildVaribles(Es)
!     use types
!     use FVsolver, only: U
!     use mesh, only: nElem, area
!     use constants, only: tempTot_inf, pTot_inf, R_gasconst, gam
!     ! returns the pressure in each cell

!     real(dp), intent(out):: Es ! total entropy error

!     real(dp):: entropyTot, areaTot, rhoTot_inf, c
!     integer:: idx_elem

!     IF( ALLOCATED(p) ) DEALLOCATE( p, entropy, mach )

!     allocate(p(nElem), entropy(nElem), mach(nElem))




!     rhoTot_inf = pTot_inf/(R_gasconst*tempTot_inf)
!     entropyTot = pTot_inf/rhoTot_inf**gam


!     Es = 0
!     areaTot = 0
!     do idx_elem = 1, nElem
!       p(idx_elem) = (gam - 1.0_dp)*(U(4,idx_elem) - 0.5_dp*(norm2(U(2:3,idx_elem))**2)/U(1,idx_elem))
!       entropy(idx_elem) = p(idx_elem)/ U(1,idx_elem)**gam
!       Es = Es + (entropy(idx_elem)/entropyTot - 1)**2 * area(idx_elem)
!       areaTot = AreaTot + area(idx_elem)


!       c = sqrt(gam*p(idx_elem)/U(1,idx_elem))
!       mach(idx_elem) = norm2(U(2:3, idx_elem))/U(1, idx_elem)/c
!     enddo
!     Es = sqrt(Es/areaTot)

!   end subroutine !getPressure

!   subroutine getWallPressure(idxs_edge_wall, nWallElem,  pb)
!     use mesh, only: bcEdge2Elem, elem2dX, bcNormal
!     use FVsolver, only: U, dU_dX
!     use constants, only: gam


!     integer, intent(in):: nWallElem
!     integer, dimension(nWallElem), intent(in):: idxs_edge_wall
!     real(dp), dimension(nWallElem):: pb, p
!     integer:: idx, idx_elem, idx_edge, idx_state, idx_face
!     real(dp), dimension(4):: dU, U_edge
!     real(dp), dimension(2):: dX
!     real(dp):: rL, unL, qL, utL

!     !f2py intent(in) :: idxs_edge_wall, threshold
!     !f2py intent(hide), depend(idxs_edge_wall, pb) :: nWallElem = shape(idxs_edge_wall, 0)
!     !f2py intent(out) pb



!     ! write(*,*) elem2dX

!     do idx = 1,nWallElem
!       idx_edge = idxs_edge_wall(idx)
!       idx_elem = bcEdge2Elem(1,idx_edge)
!       idx_face = bcEdge2Elem(2,idx_edge)

!       dX= elem2dX(:,bcEdge2Elem(2,idx_edge), idx_elem)

!       ! write(*,*) 'dx', dX
!       do idx_state = 1,4
!         dU(idx_state) = dot_product(dX, dU_dX(:, idx_state ,idx) )
!       end do
!       U_edge = U(:, idx_elem) + dU
!       ! write(*,*) 'dU', dU, 'dX', dX, idx_elem


!       ! pb(idx) = (gam - 1.0_dp)*(U_edge(4) - 0.5_dp*(norm2(U_edge(2:3))**2)/U_edge(1))
!       rL = U_edge(1)
!       unL = dot_product(U_edge(2:3), bcNormal(:,idx_edge))/rL
!       qL  = sqrt(U_edge(2)**2 + U_edge(3)**2)/rL;
!       utL = sqrt(qL**2 - unL**2);

!       p(idx) = (gam-1)*(U_edge(4) - 0.5_dp*rL*utL**2)

!       pb(idx) = (gam - 1.0_dp)*(U_edge(4) - 0.5_dp*(norm2(U_edge(2:3))**2)/U_edge(1))

!       write(*,*) p(idx), pb(idx)
!     enddo

!     end subroutine ! getWallPressure


! end module postProcess


